module Memo
  # Main service class for semantic search operations
  #
  # Encapsulates configuration and provides clean API for indexing and search.
  #
  # ## Usage
  #
  # ```
  # # Initialize service
  # memo = Memo::Service.new(
  #   db_path: "embeddings.db",
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
  class Service
    getter db : DB::Database
    getter provider : Providers::Base
    getter service_id : Int64
    getter chunking_config : Config::Chunking
    getter dimensions : Int32
    getter projection_vectors : Array(Array(Float64))

    # Track whether we own the db connection (for close behavior)
    @owns_db : Bool = true

    # Initialize service with database path
    #
    # Required:
    # - db_path: Path to database file
    # - provider: "openai" or "mock"
    # - api_key: Provider API key (not needed for mock)
    #
    # Optional:
    # - attach: Hash of alias => path for databases to ATTACH
    # - model: Embedding model (default depends on provider)
    # - dimensions: Vector dimensions (auto-detected from model)
    # - max_tokens: Provider token limit (auto-detected)
    # - chunking_max_tokens: Max tokens per chunk (default 2000)
    #
    # Example with ATTACH for unified queries:
    # ```
    # memo = Memo::Service.new(
    #   db_path: "embeddings.db",
    #   attach: {"main" => "data.db"},
    #   provider: "openai",
    #   api_key: key
    # )
    # # Now can use chunk_filter: "c.source_id IN (SELECT id FROM main.artifact ...)"
    # ```
    def initialize(
      db_path : String,
      provider : String,
      api_key : String? = nil,
      model : String? = nil,
      dimensions : Int32? = nil,
      max_tokens : Int32? = nil,
      chunking_max_tokens : Int32 = 2000,
      attach : Hash(String, String)? = nil
    )
      # Open and initialize database
      @db = DB.open("sqlite3://#{db_path}")
      @owns_db = true
      Database.init(@db)

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

          success_count += 1
          current_offset += chunk_size
        end
      end

      success_count
    rescue ex
      raise Exception.new("Index failed: #{ex.message}")
    end

    # Search for semantically similar chunks
    #
    # Automatically generates query embedding and searches.
    #
    # Returns array of search results ranked by similarity.
    #
    # chunk_filter: Raw SQL fragment for filtering chunks. Used with ATTACH
    #   to filter by external database tables.
    #   Example: "c.source_id IN (SELECT id FROM main.artifact WHERE kind = 'goal')"
    def search(
      query : String,
      limit : Int32 = 10,
      min_score : Float64 = 0.7,
      source_type : String? = nil,
      source_id : Int64? = nil,
      pair_id : Int64? = nil,
      parent_id : Int64? = nil,
      chunk_filter : String? = nil
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

      # Search with projection filtering
      Search.semantic(
        db: @db,
        embedding: query_embedding,
        service_id: @service_id,
        limit: limit,
        min_score: min_score,
        filters: filters,
        chunk_filter: chunk_filter,
        projection_vectors: @projection_vectors
      )
    end

    # Mark chunks as read (increment read_count)
    def mark_as_read(chunk_ids : Array(Int64))
      Search.mark_as_read(@db, chunk_ids)
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
  end
end
