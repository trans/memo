module Memo
  # Random projection operations for fast similarity filtering
  #
  # Uses random orthogonal vectors to project high-dimensional embeddings
  # into a low-dimensional space. Similar embeddings will have similar
  # projections, enabling fast pre-filtering before full cosine similarity.
  module Projection
    extend self

    # Number of projection dimensions (columns: proj_0 through proj_7)
    K = 8

    # Generate k random orthogonal unit vectors of given dimension
    #
    # Uses Gram-Schmidt orthogonalization to ensure vectors are orthogonal.
    # Each vector is normalized to unit length.
    def generate_orthogonal_vectors(dimensions : Int32, k : Int32 = K) : Array(Array(Float64))
      random = Random.new
      vectors = [] of Array(Float64)

      k.times do
        # Start with random vector
        vec = Array.new(dimensions) { random.next_float * 2.0 - 1.0 }

        # Gram-Schmidt: subtract projections onto previous vectors
        vectors.each do |prev|
          dot = dot_product(vec, prev)
          dimensions.times do |i|
            vec[i] -= dot * prev[i]
          end
        end

        # Normalize to unit length
        vec = normalize(vec)
        vectors << vec
      end

      vectors
    end

    # Compute dot product of two vectors
    def dot_product(a : Array(Float64), b : Array(Float64)) : Float64
      sum = 0.0
      a.size.times do |i|
        sum += a[i] * b[i]
      end
      sum
    end

    # Normalize vector to unit length
    def normalize(vec : Array(Float64)) : Array(Float64)
      magnitude = Math.sqrt(vec.sum { |v| v * v })
      return vec if magnitude == 0.0
      vec.map { |v| v / magnitude }
    end

    # Compute projections of an embedding onto projection vectors
    #
    # Returns k dot products (one per projection vector)
    def compute_projections(embedding : Array(Float64), proj_vectors : Array(Array(Float64))) : Array(Float64)
      proj_vectors.map { |vec| dot_product(embedding, vec) }
    end

    # Store projection vectors for a service
    def store_projection_vectors(
      db : DB::Database,
      service_id : Int64,
      vectors : Array(Array(Float64))
    )
      prefix = Memo.table_prefix

      blobs = vectors.map { |vec| Storage.serialize_embedding(vec) }

      db.exec(
        "INSERT OR REPLACE INTO #{prefix}projection_vectors
         (service_id, vec_0, vec_1, vec_2, vec_3, vec_4, vec_5, vec_6, vec_7, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        service_id,
        blobs[0], blobs[1], blobs[2], blobs[3],
        blobs[4], blobs[5], blobs[6], blobs[7],
        Time.utc.to_unix_ms
      )
    end

    # Get projection vectors for a service
    #
    # Returns nil if not found
    def get_projection_vectors(db : DB::Database, service_id : Int64) : Array(Array(Float64))?
      prefix = Memo.table_prefix

      db.query_one?(
        "SELECT vec_0, vec_1, vec_2, vec_3, vec_4, vec_5, vec_6, vec_7
         FROM #{prefix}projection_vectors
         WHERE service_id = ?",
        service_id
      ) do |rs|
        vectors = [] of Array(Float64)
        K.times do
          blob = rs.read(Bytes)
          vectors << Storage.deserialize_embedding(blob)
        end
        vectors
      end
    end

    # Store projections for an embedding
    def store_projections(
      db : DB::Database,
      hash : Bytes,
      projections : Array(Float64)
    )
      prefix = Memo.table_prefix

      db.exec(
        "INSERT OR REPLACE INTO #{prefix}projections
         (hash, proj_0, proj_1, proj_2, proj_3, proj_4, proj_5, proj_6, proj_7)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        hash,
        projections[0], projections[1], projections[2], projections[3],
        projections[4], projections[5], projections[6], projections[7]
      )
    end

    # Get projections for an embedding
    #
    # Returns nil if not found
    def get_projections(db : DB::Database, hash : Bytes) : Array(Float64)?
      prefix = Memo.table_prefix

      db.query_one?(
        "SELECT proj_0, proj_1, proj_2, proj_3, proj_4, proj_5, proj_6, proj_7
         FROM #{prefix}projections
         WHERE hash = ?",
        hash
      ) do |rs|
        projections = [] of Float64
        K.times do
          projections << rs.read(Float64)
        end
        projections
      end
    end

    # Compute squared Euclidean distance between two projection vectors
    #
    # Used for fast filtering - smaller distance means more likely to be similar
    def projection_distance_squared(a : Array(Float64), b : Array(Float64)) : Float64
      sum = 0.0
      a.size.times do |i|
        diff = a[i] - b[i]
        sum += diff * diff
      end
      sum
    end
  end
end
