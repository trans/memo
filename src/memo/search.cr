module Memo
  # Semantic search operations using USearch HNSW index
  module Search
    extend self

    # Search result struct
    #
    # Returns external source IDs (Int64, String, or Bytes), matching what was indexed.
    # source_id may be nil for memo-managed sources (e.g., file indexer).
    struct Result
      getter chunk_id : Int64
      getter hash : Bytes
      getter source_type : String
      getter source_id : ExternalId?       # External ID (nil for memo-managed sources)
      getter internal_source_id : Int64    # Internal ID (FK to sources)
      getter pair_id : ExternalId?
      getter parent_id : ExternalId?
      getter offset : Int32?
      getter size : Int32
      getter match_count : Int32
      getter read_count : Int32
      getter score : Float64
      getter text : String?  # Only populated with detail level

      def initialize(
        @chunk_id, @hash, @source_type, @source_id, @internal_source_id,
        @pair_id, @parent_id, @offset, @size,
        @match_count, @read_count, @score, @text = nil
      )
      end
    end

    # Filters for semantic search
    #
    # Uses internal IDs for filtering (resolved by Service.search from external IDs)
    struct Filters
      property source_type : String?
      property internal_source_id : Int64?
      property internal_pair_id : Int64?
      property internal_parent_id : Int64?

      def initialize(
        @source_type = nil,
        @internal_source_id = nil,
        @internal_pair_id = nil,
        @internal_parent_id = nil
      )
      end
    end

    # Semantic search using USearch HNSW index
    #
    # Returns results ranked by cosine similarity.
    #
    # IMPORTANT: Must provide service_id to ensure embeddings are from same vector space.
    #
    # When metadata filters are present (source_type, like, match, sql_where),
    # pre-filters via SQL to get valid embedding rowids, then uses USearch
    # filtered_search. When no filters, uses direct USearch search.
    def semantic(
      db : DB::Database,
      embedding : Array(Float64),
      service_id : Int64,
      usearch_index : USearch::Index,
      limit : Int32 = 10,
      min_score : Float64 = 0.7,
      filters : Filters? = nil,
      detail : Symbol = :reference,
      sql_where : String? = nil,
      like : Array(String)? = nil,
      match : String? = nil,
      include_text : Bool = true
    ) : Array(Result)
      prefix = db.memo_table_prefix

      has_filters = filters || sql_where || (like && !like.empty?) || (match && !match.empty?)

      # Get nearest neighbor candidates from USearch
      usearch_results = if has_filters
                           search_filtered(db, usearch_index, embedding, service_id, limit, filters, sql_where, like, match)
                         else
                           USearchIndex.search(usearch_index, embedding, limit)
                         end

      return [] of Result if usearch_results.empty?

      # Build score lookup (cosine distance → similarity)
      scores = {} of UInt64 => Float64
      usearch_results.each do |r|
        score = 1.0 - r.distance.to_f64
        next if score < min_score
        scores[r.key] = score
      end

      return [] of Result if scores.empty?

      # Batch-fetch chunk metadata for matching rowids
      fetch_results(db, service_id, scores, limit, include_text)
    end

    # Mark chunks as read (increment read_count)
    def mark_as_read(db : DB::Database, chunk_ids : Array(Int64))
      Storage.increment_read_count(db, chunk_ids)
    end

    # Pre-filter via SQL, then use USearch filtered_search
    private def search_filtered(
      db : DB::Database,
      usearch_index : USearch::Index,
      embedding : Array(Float64),
      service_id : Int64,
      limit : Int32,
      filters : Filters?,
      sql_where : String?,
      like : Array(String)?,
      match : String?
    ) : Array(USearch::SearchResult)
      prefix = db.memo_table_prefix

      # Build SQL to get valid embedding rowids
      where_clauses = ["e.service_id = ?"] of String
      params = [service_id] of DB::Any

      if f = filters
        if source_type = f.source_type
          where_clauses << "c.source_type = ?"
          params << source_type
        end
        if source_id = f.internal_source_id
          where_clauses << "c.source_id = ?"
          params << source_id
        end
        if pair_id = f.internal_pair_id
          where_clauses << "c.pair_id = ?"
          params << pair_id
        end
        if parent_id = f.internal_parent_id
          where_clauses << "c.parent_id = ?"
          params << parent_id
        end
      end

      if sql_where && !sql_where.empty?
        where_clauses << "(#{sql_where})"
      end

      # Text joins
      text_join = ""
      fts_join = ""

      if like && !like.empty?
        text_join = "JOIN #{prefix}texts st ON c.source_id = st.source_id"
        like.each do |pattern|
          where_clauses << "st.content LIKE ?"
          params << pattern
        end
      end

      if match && !match.empty?
        fts_join = "JOIN #{prefix}texts_fts ON c.source_id = #{prefix}texts_fts.source_id"
        where_clauses << "#{prefix}texts_fts MATCH ?"
        params << match
      end

      # Query for valid rowids
      valid_rowids = Set(UInt64).new

      db.query(
        <<-SQL,
          SELECT DISTINCT e.rowid
          FROM #{prefix}chunks c
          JOIN #{prefix}embeddings e ON c.hash = e.hash AND e.service_id = ?
          #{text_join}
          #{fts_join}
          WHERE #{where_clauses.join(" AND ")}
        SQL
        args: [service_id] + params
      ) do |rs|
        rs.each do
          valid_rowids << rs.read(Int64).to_u64
        end
      end

      return [] of USearch::SearchResult if valid_rowids.empty?

      # Use USearch filtered search with the valid set
      USearchIndex.filtered_search(usearch_index, embedding, limit) do |key|
        valid_rowids.includes?(key)
      end
    end

    # Fetch chunk metadata for USearch results
    private def fetch_results(
      db : DB::Database,
      service_id : Int64,
      scores : Hash(UInt64, Float64),
      limit : Int32,
      include_text : Bool
    ) : Array(Result)
      prefix = db.memo_table_prefix
      rowids = scores.keys.map(&.to_i64)

      # Build text select/join if needed
      text_select = include_text ? ", SUBSTR(st.content, c.offset + 1, c.size) AS chunk_text" : ""
      text_join = include_text ? "LEFT JOIN #{prefix}texts st ON c.source_id = st.source_id" : ""

      placeholders = rowids.map { "?" }.join(", ")

      results = [] of Result

      db.query(
        <<-SQL,
          SELECT e.rowid, c.id, c.hash, c.source_type, c.source_id,
                 s.external_int, s.external_text, s.external_blob,
                 c.pair_id, ps.external_int, ps.external_text, ps.external_blob,
                 c.parent_id, prs.external_int, prs.external_text, prs.external_blob,
                 c.offset, c.size, c.match_count, c.read_count
                 #{text_select}
          FROM #{prefix}embeddings e
          JOIN #{prefix}chunks c ON c.hash = e.hash
          JOIN #{prefix}sources s ON c.source_id = s.id
          LEFT JOIN #{prefix}sources ps ON c.pair_id = ps.id
          LEFT JOIN #{prefix}sources prs ON c.parent_id = prs.id
          #{text_join}
          WHERE e.rowid IN (#{placeholders})
            AND e.service_id = ?
        SQL
        args: rowids.map(&.as(DB::Any)) + [service_id.as(DB::Any)]
      ) do |rs|
        rs.each do
          embedding_rowid = rs.read(Int64).to_u64
          chunk_id = rs.read(Int64)
          hash = rs.read(Bytes)
          source_type = rs.read(String)
          internal_source_id = rs.read(Int64)
          external_int = rs.read(Int64?)
          external_text = rs.read(String?)
          external_blob = rs.read(Bytes?)
          internal_pair_id = rs.read(Int64?)
          pair_external_int = rs.read(Int64?)
          pair_external_text = rs.read(String?)
          pair_external_blob = rs.read(Bytes?)
          internal_parent_id = rs.read(Int64?)
          parent_external_int = rs.read(Int64?)
          parent_external_text = rs.read(String?)
          parent_external_blob = rs.read(Bytes?)
          offset = rs.read(Int32?)
          size = rs.read(Int32)
          match_count = rs.read(Int32)
          read_count = rs.read(Int32)
          text_content = include_text ? rs.read(String?) : nil

          score = scores[embedding_rowid]? || 0.0

          # Build external IDs (may be nil for memo-managed sources)
          external_source_id : ExternalId? = external_int || external_text || external_blob
          external_pair_id : ExternalId? = internal_pair_id ? (pair_external_int || pair_external_text || pair_external_blob) : nil
          external_parent_id : ExternalId? = internal_parent_id ? (parent_external_int || parent_external_text || parent_external_blob) : nil

          results << Result.new(
            chunk_id: chunk_id,
            hash: hash,
            source_type: source_type,
            source_id: external_source_id,
            internal_source_id: internal_source_id,
            pair_id: external_pair_id,
            parent_id: external_parent_id,
            offset: offset,
            size: size,
            match_count: match_count,
            read_count: read_count,
            score: score,
            text: text_content
          )
        end
      end

      # Sort by score descending and limit
      results.sort_by! { |r| -r.score }
      results = results.first(limit)

      # Increment match counts for results found
      Storage.increment_match_count(db, results.map(&.chunk_id))

      results
    end
  end
end
