module Memo
  # Semantic search operations
  module Search
    extend self

    # Search result struct
    struct Result
      getter chunk_id : Int64
      getter hash : Bytes
      getter source_type : String
      getter source_id : Int64
      getter pair_id : Int64?
      getter parent_id : Int64?
      getter offset : Int32?
      getter size : Int32
      getter match_count : Int32
      getter read_count : Int32
      getter score : Float64
      getter text : String?  # Only populated with detail level

      def initialize(
        @chunk_id, @hash, @source_type, @source_id,
        @pair_id, @parent_id, @offset, @size,
        @match_count, @read_count, @score, @text = nil
      )
      end
    end

    # Filters for semantic search
    struct Filters
      property source_type : String?
      property source_id : Int64?
      property pair_id : Int64?
      property parent_id : Int64?

      def initialize(
        @source_type = nil,
        @source_id = nil,
        @pair_id = nil,
        @parent_id = nil
      )
      end
    end

    # Semantic search by embedding
    #
    # Returns results ranked by cosine similarity
    #
    # IMPORTANT: Must provide service_id to ensure embeddings are from same vector space
    #
    # Detail levels:
    # - :reference (default): Just IDs and metadata
    # - :summary: Not yet implemented (for future text storage)
    # - :full: Not yet implemented (for future text storage)
    def semantic(
      db : DB::Database,
      embedding : Array(Float64),
      service_id : Int64,
      limit : Int32 = 10,
      min_score : Float64 = 0.7,
      filters : Filters? = nil,
      detail : Symbol = :reference
    ) : Array(Result)
      prefix = Memo.table_prefix

      # Build WHERE clauses
      where_clauses = [] of String
      params = [] of DB::Any

      # CRITICAL: Filter by service_id to ensure same vector space
      where_clauses << "e.service_id = ?"
      params << service_id

      if filters
        if source_type = filters.source_type
          where_clauses << "c.source_type = ?"
          params << source_type
        end
        if source_id = filters.source_id
          where_clauses << "c.source_id = ?"
          params << source_id
        end
        if pair_id = filters.pair_id
          where_clauses << "c.pair_id = ?"
          params << pair_id
        end
        if parent_id = filters.parent_id
          where_clauses << "c.parent_id = ?"
          params << parent_id
        end
      end

      where_clause = "WHERE #{where_clauses.join(" AND ")}"

      # Stream embeddings and keep only top-k results
      top_results = [] of Result

      db.query(
        <<-SQL,
          SELECT c.id, c.hash, c.source_type, c.source_id, c.pair_id, c.parent_id,
                 c.offset, c.size, c.match_count, c.read_count,
                 e.embedding
          FROM #{prefix}chunks c
          JOIN #{prefix}embeddings e ON c.hash = e.hash
          #{where_clause}
        SQL
        args: params
      ) do |rs|
        rs.each do
          chunk_id = rs.read(Int64)
          hash = rs.read(Bytes)
          source_type = rs.read(String)
          source_id = rs.read(Int64)
          pair_id = rs.read(Int64?)
          parent_id = rs.read(Int64?)
          offset = rs.read(Int32?)
          size = rs.read(Int32)
          match_count = rs.read(Int32)
          read_count = rs.read(Int32)
          embedding_blob = rs.read(Bytes)

          # Decode and compute similarity
          stored_embedding = Storage.deserialize_embedding(embedding_blob)
          score = cosine_similarity(embedding, stored_embedding)

          # Only consider if meets minimum score
          next if score < min_score

          result = Result.new(
            chunk_id: chunk_id,
            hash: hash,
            source_type: source_type,
            source_id: source_id,
            pair_id: pair_id,
            parent_id: parent_id,
            offset: offset,
            size: size,
            match_count: match_count,
            read_count: read_count,
            score: score,
            text: nil  # TODO: Support detail levels when text storage added
          )

          # Insert maintaining sorted order
          insert_sorted(top_results, result, limit)
        end
      end

      # Increment match counts for results found
      Storage.increment_match_count(db, top_results.map(&.chunk_id))

      top_results
    end

    # Mark chunks as read (increment read_count)
    def mark_as_read(db : DB::Database, chunk_ids : Array(Int64))
      Storage.increment_read_count(db, chunk_ids)
    end

    # Calculate cosine similarity between two embeddings
    #
    # Returns score between -1.0 and 1.0:
    # - 1.0 = identical vectors
    # - 0.0 = orthogonal vectors
    # - -1.0 = opposite vectors
    private def cosine_similarity(vec_a : Array(Float64), vec_b : Array(Float64)) : Float64
      raise "Vector dimensions don't match" if vec_a.size != vec_b.size

      # Compute dot product
      dot_product = vec_a.zip(vec_b).sum { |a, b| a * b }

      # Compute magnitudes (L2 norms)
      magnitude_a = Math.sqrt(vec_a.sum { |a| a * a })
      magnitude_b = Math.sqrt(vec_b.sum { |b| b * b })

      # Avoid division by zero
      return 0.0 if magnitude_a == 0.0 || magnitude_b == 0.0

      # Compute cosine similarity
      dot_product / (magnitude_a * magnitude_b)
    end

    # Insert result into sorted array, maintaining max size
    #
    # More memory efficient than sorting entire result set
    private def insert_sorted(
      results : Array(Result),
      new_result : Result,
      max_size : Int32
    )
      # Find insertion point (binary search)
      insert_idx = results.bsearch_index { |r| r.score < new_result.score } || results.size

      # Insert at position
      results.insert(insert_idx, new_result)

      # Trim to max size
      results.pop if results.size > max_size
    end
  end
end
