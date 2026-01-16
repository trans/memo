module Memo
  # Statistics about indexed content
  struct Stats
    getter embeddings : Int64
    getter chunks : Int64
    getter sources : Int64

    def initialize(@embeddings, @chunks, @sources)
    end
  end

  # Document to be indexed
  struct Document
    property source_type : String
    property source_id : Int64
    property text : String
    property pair_id : Int64?
    property parent_id : Int64?

    def initialize(
      @source_type : String,
      @source_id : Int64,
      @text : String,
      @pair_id : Int64? = nil,
      @parent_id : Int64? = nil
    )
    end
  end

  # Main service class for semantic search operations
  #
  # Encapsulates configuration and provides clean API for indexing and search.
  #
  # ## Usage
  #
  # ```
  # # Initialize service with data directory
  # memo = Memo::Service.new(
  #   data_dir: "/var/data/memo",
  #   provider: "openai",
  #   api_key: ENV["OPENAI_API_KEY"]
  # )
  #
  # # Index documents
  # memo.index(source_type: "event", source_id: 123, text: "Document text...")
  #
  # # Search
  # results = memo.search(query: "search query", limit: 10)
  #
  # # Clean up
  # memo.close
  # ```
  #
  # ## Database Files
  #
  # Memo stores data in the specified directory:
  # - embeddings.db: Embeddings, chunks, projections (regenerable)
  # - text.db: Text content (future, persistent)
  #
  class Service
    getter db : DB::Database
    getter provider : Providers::Base
    getter service_id : Int64
    getter chunking_config : Config::Chunking
    getter dimensions : Int32
    getter projection_vectors : Array(Array(Float64))
    getter data_dir : String?

    # Schema name for ATTACHed text database
    TEXT_SCHEMA = "text_store"

    # Track whether we own the db connection (for close behavior)
    @owns_db : Bool = true

    # Track whether text storage is enabled
    getter? text_storage : Bool = false

    # Initialize service with data directory
    #
    # Required:
    # - data_dir: Directory path for database files
    # - provider: "openai" or "mock"
    # - api_key: Provider API key (not needed for mock)
    #
    # Optional:
    # - store_text: Enable text storage in text.db (default true)
    # - attach: Hash of alias => path for databases to ATTACH
    # - model: Embedding model (default depends on provider)
    # - dimensions: Vector dimensions (auto-detected from model)
    # - max_tokens: Provider token limit (auto-detected)
    # - chunking_max_tokens: Max tokens per chunk (default 2000)
    #
    # Example with ATTACH for unified queries:
    # ```
    # memo = Memo::Service.new(
    #   data_dir: "/var/data/memo",
    #   attach: {"main" => "data.db"},
    #   provider: "openai",
    #   api_key: key
    # )
    # # Now can use chunk_filter: "c.source_id IN (SELECT id FROM main.artifact ...)"
    # ```
    def initialize(
      data_dir : String,
      provider : String,
      api_key : String? = nil,
      model : String? = nil,
      dimensions : Int32? = nil,
      max_tokens : Int32? = nil,
      chunking_max_tokens : Int32 = 2000,
      store_text : Bool = true,
      attach : Hash(String, String)? = nil
    )
      # Store data directory
      @data_dir = data_dir

      # Create directory if it doesn't exist
      Dir.mkdir_p(data_dir) unless Dir.exists?(data_dir)

      # Open and initialize embeddings database
      embeddings_path = File.join(data_dir, "embeddings.db")
      @db = DB.open("sqlite3://#{embeddings_path}")
      @owns_db = true
      Database.init(@db)

      # ATTACH and initialize text database if text storage enabled
      if store_text
        text_path = File.join(data_dir, "text.db")
        @db.exec("ATTACH DATABASE '#{text_path}' AS #{TEXT_SCHEMA}")
        Database.init_text_db(@db, TEXT_SCHEMA)
        @text_storage = true
      end

      # ATTACH additional databases if specified
      attach.try &.each do |db_alias, path|
        @db.exec("ATTACH DATABASE '#{path}' AS #{db_alias}")
      end

      # Standalone mode - no table prefix
      Memo.table_prefix = ""

      # Create provider instance
      @provider = case provider
                  when "openai"
                    raise ArgumentError.new("api_key required for openai provider") unless api_key
                    Providers::OpenAI.new(api_key, model || "text-embedding-3-small")
                  when "mock"
                    Providers::Mock.new
                  else
                    raise ArgumentError.new("Unknown provider: #{provider}")
                  end

      # Auto-detect dimensions and max_tokens from provider/model
      final_model = model || default_model(provider)
      final_dimensions = dimensions || default_dimensions(provider, final_model)
      final_max_tokens = max_tokens || default_max_tokens(provider, final_model)

      # Validate chunking doesn't exceed provider limits
      if chunking_max_tokens > final_max_tokens
        raise ArgumentError.new("chunking_max_tokens (#{chunking_max_tokens}) exceeds provider limit (#{final_max_tokens})")
      end

      # Store dimensions for projection vector generation
      @dimensions = final_dimensions

      # Register service in database
      @service_id = Storage.register_service(
        db: @db,
        provider: provider,
        model: final_model,
        version: nil,
        dimensions: final_dimensions,
        max_tokens: final_max_tokens
      )

      # Get or create projection vectors for this service
      @projection_vectors = Projection.get_projection_vectors(@db, @service_id) ||
                            create_projection_vectors

      # Create chunking config
      @chunking_config = Config::Chunking.new(
        min_tokens: 100,
        max_tokens: chunking_max_tokens,
        no_chunk_threshold: chunking_max_tokens
      )
    end

    # Initialize service with existing database connection
    #
    # Use this when caller manages the connection lifecycle.
    # Caller is responsible for closing the connection.
    def initialize(
      db : DB::Database,
      provider : String,
      api_key : String? = nil,
      model : String? = nil,
      dimensions : Int32? = nil,
      max_tokens : Int32? = nil,
      chunking_max_tokens : Int32 = 2000
    )
      @db = db
      @data_dir = nil  # No data directory when using external connection
      @owns_db = false  # Caller owns the connection
      Database.init(@db)

      # Standalone mode - no table prefix
      Memo.table_prefix = ""

      # Create provider instance
      @provider = case provider
                  when "openai"
                    raise ArgumentError.new("api_key required for openai provider") unless api_key
                    Providers::OpenAI.new(api_key, model || "text-embedding-3-small")
                  when "mock"
                    Providers::Mock.new
                  else
                    raise ArgumentError.new("Unknown provider: #{provider}")
                  end

      # Auto-detect dimensions and max_tokens from provider/model
      final_model = model || default_model(provider)
      final_dimensions = dimensions || default_dimensions(provider, final_model)
      final_max_tokens = max_tokens || default_max_tokens(provider, final_model)

      # Validate chunking doesn't exceed provider limits
      if chunking_max_tokens > final_max_tokens
        raise ArgumentError.new("chunking_max_tokens (#{chunking_max_tokens}) exceeds provider limit (#{final_max_tokens})")
      end

      # Store dimensions for projection vector generation
      @dimensions = final_dimensions

      # Register service in database
      @service_id = Storage.register_service(
        db: @db,
        provider: provider,
        model: final_model,
        version: nil,
        dimensions: final_dimensions,
        max_tokens: final_max_tokens
      )

      # Get or create projection vectors for this service
      @projection_vectors = Projection.get_projection_vectors(@db, @service_id) ||
                            create_projection_vectors

      # Create chunking config
      @chunking_config = Config::Chunking.new(
        min_tokens: 100,
        max_tokens: chunking_max_tokens,
        no_chunk_threshold: chunking_max_tokens
      )
    end

    # Index a document
    #
    # Chunks text, generates embeddings, and stores with source reference.
    #
    # Returns number of chunks successfully stored.
    def index(
      source_type : String,
      source_id : Int64,
      text : String,
      pair_id : Int64? = nil,
      parent_id : Int64? = nil
    ) : Int32
      # Chunk text
      chunks = Chunking.chunk_text(text, @chunking_config)
      return 0 if chunks.empty?

      # Embed chunks
      embed_result = @provider.embed_texts(chunks)

      # Store chunks
      success_count = 0
      current_offset = 0

      @db.transaction do
        chunks.each_with_index do |chunk_text, idx|
          hash = Storage.compute_hash(chunk_text)
          embedding = embed_result.embeddings[idx]
          token_count = embed_result.token_counts[idx]
          chunk_size = chunk_text.size

          # Store embedding (deduplicated by hash)
          Storage.store_embedding(@db, hash, embedding, token_count, @service_id)

          # Compute and store projections for fast filtering
          projections = Projection.compute_projections(embedding, @projection_vectors)
          Projection.store_projections(@db, hash, projections)

          # Create chunk reference
          Storage.create_chunk(
            db: @db,
            hash: hash,
            source_type: source_type,
            source_id: source_id,
            offset: current_offset,
            size: chunk_size,
            pair_id: pair_id,
            parent_id: parent_id
          )

          # Store text content if text storage is enabled
          store_text(hash, chunk_text) if @text_storage

          success_count += 1
          current_offset += chunk_size
        end
      end

      success_count
    rescue ex
      raise Exception.new("Index failed: #{ex.message}")
    end

    # Index a document (Document overload)
    #
    # Convenience method that accepts a Document struct.
    def index(doc : Document) : Int32
      index(
        source_type: doc.source_type,
        source_id: doc.source_id,
        text: doc.text,
        pair_id: doc.pair_id,
        parent_id: doc.parent_id
      )
    end

    # Index multiple documents in a batch
    #
    # More efficient than calling index() multiple times:
    # - Chunks all documents
    # - Embeds all chunks in fewer API calls
    # - Stores all in a single transaction
    #
    # Returns total number of chunks successfully stored.
    def index_batch(docs : Array(Document)) : Int32
      return 0 if docs.empty?

      # Chunk all documents and track which chunks belong to which doc
      doc_chunks = [] of {Document, Array(String)}
      all_chunks = [] of String

      docs.each do |doc|
        chunks = Chunking.chunk_text(doc.text, @chunking_config)
        next if chunks.empty?
        doc_chunks << {doc, chunks}
        all_chunks.concat(chunks)
      end

      return 0 if all_chunks.empty?

      # Embed all chunks in one batch call
      embed_result = @provider.embed_texts(all_chunks)

      # Store all chunks in a single transaction
      success_count = 0
      embed_idx = 0

      @db.transaction do
        doc_chunks.each do |doc, chunks|
          current_offset = 0

          chunks.each do |chunk_text|
            hash = Storage.compute_hash(chunk_text)
            embedding = embed_result.embeddings[embed_idx]
            token_count = embed_result.token_counts[embed_idx]
            chunk_size = chunk_text.size

            # Store embedding (deduplicated by hash)
            Storage.store_embedding(@db, hash, embedding, token_count, @service_id)

            # Compute and store projections for fast filtering
            projections = Projection.compute_projections(embedding, @projection_vectors)
            Projection.store_projections(@db, hash, projections)

            # Create chunk reference
            Storage.create_chunk(
              db: @db,
              hash: hash,
              source_type: doc.source_type,
              source_id: doc.source_id,
              offset: current_offset,
              size: chunk_size,
              pair_id: doc.pair_id,
              parent_id: doc.parent_id
            )

            # Store text content if text storage is enabled
            store_text(hash, chunk_text) if @text_storage

            success_count += 1
            current_offset += chunk_size
            embed_idx += 1
          end
        end
      end

      success_count
    rescue ex
      raise Exception.new("Batch index failed: #{ex.message}")
    end

    # Search for semantically similar chunks
    #
    # Automatically generates query embedding and searches.
    #
    # Returns array of search results ranked by similarity.
    #
    # like: LIKE pattern(s) to filter by text content.
    #   Single string or array of strings for AND filtering.
    #   Example: like: "%cats%" or like: ["%cats%", "%dogs%"]
    #   Only works when text storage is enabled.
    #
    # match: FTS5 full-text search query.
    #   Supports AND, OR, NOT, prefix*, "phrases".
    #   Example: match: "cats OR dogs", match: "quick brown*"
    #   Only works when text storage is enabled.
    #
    # chunk_filter: Raw SQL fragment for filtering chunks. Used with ATTACH
    #   to filter by external database tables.
    #   Example: "c.source_id IN (SELECT id FROM main.artifact WHERE kind = 'goal')"
    #
    # include_text: If true, includes text content in search results.
    #   Only works when text storage is enabled.
    def search(
      query : String,
      limit : Int32 = 10,
      min_score : Float64 = 0.7,
      source_type : String? = nil,
      source_id : Int64? = nil,
      pair_id : Int64? = nil,
      parent_id : Int64? = nil,
      like : String | Array(String) | Nil = nil,
      match : String? = nil,
      chunk_filter : String? = nil,
      include_text : Bool = false
    ) : Array(Search::Result)
      # Generate query embedding
      query_embedding, _tokens = @provider.embed_text(query)

      # Build filters
      filters = if source_type || source_id || pair_id || parent_id
                  Search::Filters.new(
                    source_type: source_type,
                    source_id: source_id,
                    pair_id: pair_id,
                    parent_id: parent_id
                  )
                else
                  nil
                end

      # Normalize like to array
      like_patterns = case like
                      when String then [like]
                      when Array  then like
                      else             nil
                      end

      # Search with projection filtering
      Search.semantic(
        db: @db,
        embedding: query_embedding,
        service_id: @service_id,
        limit: limit,
        min_score: min_score,
        filters: filters,
        chunk_filter: chunk_filter,
        projection_vectors: @projection_vectors,
        like: @text_storage ? like_patterns : nil,
        match: @text_storage ? match : nil,
        text_schema: @text_storage ? TEXT_SCHEMA : nil,
        include_text: @text_storage && include_text
      )
    end

    # Mark chunks as read (increment read_count)
    def mark_as_read(chunk_ids : Array(Int64))
      Search.mark_as_read(@db, chunk_ids)
    end

    # Get statistics about indexed content
    #
    # Returns counts of embeddings, chunks, and unique sources.
    def stats : Stats
      prefix = Memo.table_prefix

      embeddings = @db.scalar(
        "SELECT COUNT(*) FROM #{prefix}embeddings WHERE service_id = ?",
        @service_id
      ).as(Int64)

      chunks = @db.scalar(
        "SELECT COUNT(*) FROM #{prefix}chunks c
         JOIN #{prefix}embeddings e ON c.hash = e.hash
         WHERE e.service_id = ?",
        @service_id
      ).as(Int64)

      sources = @db.scalar(
        "SELECT COUNT(DISTINCT c.source_id) FROM #{prefix}chunks c
         JOIN #{prefix}embeddings e ON c.hash = e.hash
         WHERE e.service_id = ?",
        @service_id
      ).as(Int64)

      Stats.new(embeddings, chunks, sources)
    end

    # Delete all chunks for a source
    #
    # Removes all chunks with the given source_id (and optionally source_type).
    # Orphaned embeddings (not referenced by any chunk) are also cleaned up.
    #
    # Returns number of chunks deleted.
    #
    # source_type: Optional filter to only delete chunks with matching source_type.
    #   If nil, deletes all chunks with the given source_id regardless of type.
    #
    # TODO: Consider adding delete_batch(source_ids : Array(Int64)) if bulk deletion
    #       becomes a common use case. Unlike index_batch, there's no API call savings,
    #       but it could reduce transaction overhead for large deletions.
    def delete(source_id : Int64, source_type : String? = nil) : Int32
      prefix = Memo.table_prefix

      # Build query based on whether source_type is provided
      type_filter = source_type ? " AND c.source_type = ?" : ""
      query_params = source_type ? [source_id, @service_id, source_type] : [source_id, @service_id]

      # Get hashes of chunks to be deleted (for orphan cleanup)
      hashes = [] of Bytes
      @db.query(
        "SELECT DISTINCT c.hash FROM #{prefix}chunks c
         JOIN #{prefix}embeddings e ON c.hash = e.hash
         WHERE c.source_id = ? AND e.service_id = ?#{type_filter}",
        args: query_params
      ) do |rs|
        rs.each do
          hashes << rs.read(Bytes)
        end
      end

      return 0 if hashes.empty?

      deleted_count = 0

      @db.transaction do
        # Delete chunks
        hashes.each do |hash|
          if source_type
            @db.exec(
              "DELETE FROM #{prefix}chunks WHERE hash = ? AND source_id = ? AND source_type = ?",
              hash, source_id, source_type
            )
          else
            @db.exec(
              "DELETE FROM #{prefix}chunks WHERE hash = ? AND source_id = ?",
              hash, source_id
            )
          end
        end

        deleted_count = hashes.size

        # Clean up orphaned embeddings and projections
        hashes.each do |hash|
          # Check if any chunks still reference this hash
          remaining = @db.scalar(
            "SELECT COUNT(*) FROM #{prefix}chunks WHERE hash = ?",
            hash
          ).as(Int64)

          if remaining == 0
            # No more references - delete embedding and projections
            @db.exec("DELETE FROM #{prefix}projections WHERE hash = ?", hash)
            @db.exec("DELETE FROM #{prefix}embeddings WHERE hash = ?", hash)
          end
        end
      end

      deleted_count
    end

    # Close database connection
    #
    # Should be called when done with service to free resources.
    # Safe to call multiple times.
    #
    # Note: If service was initialized with an existing db connection,
    # close is a no-op (caller owns the connection).
    def close
      return unless @owns_db
      @db.close
    rescue
      # Already closed or other error - ignore
    end

    # Provider defaults (could move to Provider classes later)
    private def default_model(provider : String) : String
      case provider
      when "openai" then "text-embedding-3-small"
      when "mock"   then "mock-8d"
      else               raise "Unknown provider"
      end
    end

    private def default_dimensions(provider : String, model : String) : Int32
      case provider
      when "openai"
        case model
        when "text-embedding-3-small" then 1536
        when "text-embedding-3-large" then 3072
        else                               1536
        end
      when "mock" then 8
      else             raise "Unknown provider"
      end
    end

    private def default_max_tokens(provider : String, model : String) : Int32
      case provider
      when "openai" then 8191
      when "mock"   then 100
      else               raise "Unknown provider"
      end
    end

    # Generate and store projection vectors for this service
    private def create_projection_vectors : Array(Array(Float64))
      vectors = Projection.generate_orthogonal_vectors(@dimensions)
      Projection.store_projection_vectors(@db, @service_id, vectors)
      vectors
    end

    # Store text content in text.db (deduplicated by hash)
    # Also populates FTS5 index for full-text search
    private def store_text(hash : Bytes, content : String)
      # Insert into main texts table
      @db.exec(
        "INSERT OR IGNORE INTO #{TEXT_SCHEMA}.texts (hash, content) VALUES (?, ?)",
        hash, content
      )

      # Insert into FTS5 index (also deduplicated via INSERT OR IGNORE behavior)
      # FTS5 doesn't support INSERT OR IGNORE, so we check first
      existing = @db.query_one?(
        "SELECT 1 FROM #{TEXT_SCHEMA}.texts_fts WHERE hash = ?",
        hash,
        as: Int32
      )
      unless existing
        @db.exec(
          "INSERT INTO #{TEXT_SCHEMA}.texts_fts (hash, content) VALUES (?, ?)",
          hash, content
        )
      end
    end

    # Get text content by hash
    private def get_text(hash : Bytes) : String?
      @db.query_one?(
        "SELECT content FROM #{TEXT_SCHEMA}.texts WHERE hash = ?",
        hash,
        as: String
      )
    end
  end
end
