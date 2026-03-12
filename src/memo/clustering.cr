# Sequential clustering for chronologically ordered sources.
#
# Detects topic boundaries by finding similarity drops between
# consecutive items. Useful for dialog summarization, document
# sectioning, and any time-series semantic data.
#
# ## Example
#
# ```
# # Get clusters for a sequence of events
# clusters = Memo::Clustering.sequential(
#   db: db,
#   service_id: service.service_id,
#   source_type: "event",
#   external_ids: [100_i64, 101_i64, 102_i64, ...],
#   threshold: 0.75
# )
#
# clusters.each do |cluster|
#   puts "[E#{cluster.start_id}-E#{cluster.end_id}] #{cluster.size} events"
# end
# ```
module Memo
  module Clustering
    extend self

    # Cluster of consecutive sources with similar embeddings.
    struct Cluster
      # First source's external_id in the cluster
      getter start_id : Int64

      # Last source's external_id in the cluster
      getter end_id : Int64

      # All external_ids in the cluster (in order)
      getter source_ids : Array(Int64)

      # Number of sources in the cluster
      getter size : Int32

      def initialize(@start_id, @end_id, @source_ids, @size)
      end
    end

    # Sequential clustering for chronologically ordered sources.
    #
    # Finds topic boundaries by detecting similarity drops between
    # consecutive items. Preserves chronological order.
    #
    # Algorithm:
    # 1. Load full embeddings for all external_ids (in order)
    # 2. Compute cosine similarity between each consecutive pair
    # 3. Mark indices where similarity < threshold as boundaries
    # 4. Group source_ids between boundaries into clusters
    # 5. Filter out clusters smaller than min_cluster_size
    #
    # Returns array of Cluster structs representing topic groups.
    # Sources without embeddings are skipped.
    def sequential(
      db : DB::Database,
      service_id : Int64,
      usearch_index : USearch::Index,
      source_type : String,
      external_ids : Array(Int64),
      threshold : Float64 = 0.75,
      min_cluster_size : Int32 = 3
    ) : Array(Cluster)
      return [] of Cluster if external_ids.size < min_cluster_size

      # Load embeddings for all sources (preserving order)
      embeddings = load_embeddings(db, service_id, usearch_index, source_type, external_ids)
      return [] of Cluster if embeddings.size < min_cluster_size

      # Get ordered list of IDs that have embeddings
      ids_with_embeddings = external_ids.select { |id| embeddings.has_key?(id) }
      return [] of Cluster if ids_with_embeddings.size < min_cluster_size

      # Compute consecutive similarities and find boundaries
      boundaries = find_boundaries(ids_with_embeddings, embeddings, threshold)

      # Group into clusters
      clusters = build_clusters(ids_with_embeddings, boundaries)

      # Filter by minimum size
      clusters.select { |c| c.size >= min_cluster_size }
    end

    # Load embeddings for a list of external IDs.
    #
    # Returns a hash mapping external_id => embedding vector.
    # Retrieves vectors from USearch index by rowid.
    # Sources without embeddings are omitted.
    private def load_embeddings(
      db : DB::Database,
      service_id : Int64,
      usearch_index : USearch::Index,
      source_type : String,
      external_ids : Array(Int64)
    ) : Hash(Int64, Array(Float64))
      return {} of Int64 => Array(Float64) if external_ids.empty?

      prefix = db.memo_table_prefix
      result = {} of Int64 => Array(Float64)

      # Build placeholders for IN clause
      placeholders = external_ids.map { "?" }.join(", ")

      # Query: sources → chunks → embeddings (get rowids for USearch lookup)
      # For sources with multiple chunks, we take the first one (smallest offset)
      db.query(
        <<-SQL,
          SELECT s.external_int, e.#{db.memo_dialect.embedding_rowid_column}
          FROM #{prefix}sources s
          JOIN #{prefix}chunks c ON c.source_id = s.id
          JOIN #{prefix}embeddings e ON c.hash = e.hash AND e.service_id = ?
          WHERE s.source_type = ?
            AND s.external_int IN (#{placeholders})
          GROUP BY s.external_int
          ORDER BY s.external_int, c.offset
        SQL
        args: [service_id, source_type] + external_ids.map(&.as(DB::Any))
      ) do |rs|
        rs.each do
          external_id = rs.read(Int64)
          rowid = rs.read(Int64)
          embedding = USearchIndex.get_vector(usearch_index, rowid.to_u64)
          result[external_id] = embedding if embedding
        end
      end

      result
    end

    # Find boundary indices where similarity drops below threshold.
    #
    # Returns array of indices where a new cluster should start.
    # Index 0 is always a boundary (start of first cluster).
    private def find_boundaries(
      ids : Array(Int64),
      embeddings : Hash(Int64, Array(Float64)),
      threshold : Float64
    ) : Array(Int32)
      boundaries = [0]  # First item always starts a cluster

      (0...(ids.size - 1)).each do |i|
        vec_a = embeddings[ids[i]]
        vec_b = embeddings[ids[i + 1]]
        similarity = cosine_similarity(vec_a, vec_b)

        if similarity < threshold
          # Topic shift detected - next item starts new cluster
          boundaries << (i + 1)
        end
      end

      boundaries
    end

    # Build clusters from boundary indices.
    private def build_clusters(
      ids : Array(Int64),
      boundaries : Array(Int32)
    ) : Array(Cluster)
      clusters = [] of Cluster

      boundaries.each_with_index do |start_idx, i|
        # End index is either next boundary or end of array
        end_idx = if i + 1 < boundaries.size
                    boundaries[i + 1] - 1
                  else
                    ids.size - 1
                  end

        source_ids = ids[start_idx..end_idx]
        clusters << Cluster.new(
          start_id: source_ids.first,
          end_id: source_ids.last,
          source_ids: source_ids,
          size: source_ids.size
        )
      end

      clusters
    end

    # Calculate cosine similarity between two embeddings.
    #
    # Returns score between -1.0 and 1.0:
    # - 1.0 = identical vectors
    # - 0.0 = orthogonal vectors
    # - -1.0 = opposite vectors
    private def cosine_similarity(vec_a : Array(Float64), vec_b : Array(Float64)) : Float64
      return 0.0 if vec_a.size != vec_b.size
      return 0.0 if vec_a.empty?

      # Compute dot product and magnitudes in single pass
      dot_product = 0.0
      magnitude_a_sq = 0.0
      magnitude_b_sq = 0.0

      vec_a.each_with_index do |a, i|
        b = vec_b[i]
        dot_product += a * b
        magnitude_a_sq += a * a
        magnitude_b_sq += b * b
      end

      # Avoid division by zero
      return 0.0 if magnitude_a_sq == 0.0 || magnitude_b_sq == 0.0

      # Compute cosine similarity
      dot_product / (Math.sqrt(magnitude_a_sq) * Math.sqrt(magnitude_b_sq))
    end
  end
end
