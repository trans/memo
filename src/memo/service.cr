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
  #
  # Supports both integer and string source IDs:
  # - Int64: Time-based, sortable IDs (e.g., Unix timestamps)
  # - String: UUIDs and other text identifiers
  struct Document
    property source_type : String
    property source_id : ExternalId
    property text : String
    property pair_id : ExternalId?
    property parent_id : ExternalId?

    def initialize(
      @source_type : String,
      @source_id : ExternalId,
      @text : String,
      @pair_id : ExternalId? = nil,
      @parent_id : ExternalId? = nil
    )
    end
  end

  # Main service class for semantic search operations
  #
  # Encapsulates configuration and provides clean API for indexing and search.
  #
  # ## Quick Start
  #
  # ```
  # # Initialize with default service (mock, preloaded)
  # memo = Memo::Service.new(db_path: "/var/data/memo.db")
  #
  # # Configure a real service
  # memo.create_service(
  #   name: "openai",
  #   format: "openai",
  #   model: "text-embedding-3-small",
  #   dimensions: 1536,
  #   max_tokens: 8191
  # )
  # memo.set_default_service("openai")
  #
  # # Switch to it
  # memo.use_service("openai", api_key: ENV["OPENAI_API_KEY"])
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
  # ## Service Configuration
  #
  # Services are named configurations for embedding providers:
  #
  # ```
  # memo.create_service(
  #   name: "azure-prod",
  #   format: "openai",
  #   base_url: "https://mycompany.openai.azure.com/",
  #   model: "text-embedding-ada-002",
  #   dimensions: 1536,
  #   max_tokens: 8191
  # )
  #
  # # Switch services at runtime
  # memo.use_service("azure-prod", api_key: ENV["AZURE_API_KEY"])
  # ```
  #
  # ## Database
  #
  # Memo stores all data in a single SQLite file at the provided `db_path`.
  # Contains: services, embeddings, chunks, projections, texts, queue
  #
  class Service
    getter db : DB::Database
    getter provider : Providers::Base
    getter service_id : Int64
    getter service_name : String
    getter chunking_config : Config::Chunking
    getter queue_config : Config::Queue
    getter dimensions : Int32
    getter batch_size : Int32
    getter projection_vectors : Array(Array(Float64))
    getter db_path : String?
    getter table_prefix : String

    # Private struct for init_provider return value
    private record ProviderConfig,
      provider : Providers::Base,
      service_id : Int64,
      service_name : String,
      dimensions : Int32,
      max_tokens : Int32,
      tokens_per_byte : Float64

    # Track whether we own the db connection (for close behavior)
    @owns_db : Bool = true

    # Track whether text storage is enabled
    getter? text_storage : Bool = false

    # Initialize service with database path
    #
    # Use EITHER:
    # - service: Name of pre-configured service (from ServiceProvider.create)
    # - format: API format ("openai", "mock") to configure inline
    #
    # Required:
    # - db_path: Full path to database file (e.g., "/var/data/memo.db")
    # - api_key: API key (not needed for mock format)
    #
    # Optional:
    # - service: Name of pre-configured service to use
    # - format: API format for inline configuration (default "openai")
    # - base_url: Custom API endpoint (for OpenAI-compatible APIs)
    # - model: Embedding model (default depends on format)
    # - dimensions: Vector dimensions (auto-detected from model)
    # - max_tokens: Token limit (auto-detected from model)
    # - store_text: Enable text storage in texts table (default true)
    # - chunking_max_tokens: Max tokens per chunk (default 2000)
    #
    # Example:
    # ```
    # memo = Memo::Service.new(
    #   db_path: "/var/data/memo.db",
    #   format: "openai",
    #   api_key: ENV["OPENAI_API_KEY"]
    # )
    # ```
    def initialize(
      db_path : String,
      api_key : String? = nil,
      service : String? = nil,
      format : String? = nil,
      base_url : String? = nil,
      model : String? = nil,
      dimensions : Int32? = nil,
      max_tokens : Int32? = nil,
      chunking_max_tokens : Int32 = 2000,
      store_text : Bool = true,
      batch_size : Int32 = 100,
      max_retries : Int32 = 3,
      table_prefix : String = "memo_"
    )
      # Create parent directory if it doesn't exist
      dir = File.dirname(db_path)
      Dir.mkdir_p(dir) unless dir.empty? || Dir.exists?(dir)

      # Open memo database
      @db_path = db_path
      @db = DB.open("sqlite3://#{db_path}")
      @owns_db = true
      @text_storage = store_text
      @table_prefix = table_prefix

      # Set prefix on db connection (modules read from this)
      @db.memo_table_prefix = @table_prefix

      # Initialize schema
      Database.init(@db)

      # Initialize from service name or format
      config = init_provider(
        service: service,
        format: format,
        base_url: base_url,
        model: model,
        dimensions: dimensions,
        max_tokens: max_tokens,
        api_key: api_key,
        chunking_max_tokens: chunking_max_tokens
      )

      @provider = config.provider
      @service_id = config.service_id
      @service_name = config.service_name
      @dimensions = config.dimensions

      # Get or create projection vectors for this service
      @projection_vectors = Projection.get_projection_vectors(@db, @service_id) ||
                            create_projection_vectors(@dimensions, @service_id)

      # Create chunking config with service's tokens_per_byte ratio
      @chunking_config = Config::Chunking.new(
        min_tokens: 100,
        max_tokens: chunking_max_tokens,
        no_chunk_threshold: chunking_max_tokens,
        tokens_per_byte: config.tokens_per_byte
      )

      # Store batch size and queue config
      @batch_size = batch_size
      @queue_config = Config::Queue.new(max_retries: max_retries)
    end

    # Initialize service with existing database connection
    #
    # Use this when caller manages the connection lifecycle.
    # Caller is responsible for closing the connection.
    #
    # The db_path is queried from the database for CLI use. Pass db_path
    # explicitly if the pragma query doesn't work for your setup.
    def initialize(
      db : DB::Database,
      api_key : String? = nil,
      service : String? = nil,
      format : String? = nil,
      base_url : String? = nil,
      model : String? = nil,
      dimensions : Int32? = nil,
      max_tokens : Int32? = nil,
      chunking_max_tokens : Int32 = 2000,
      store_text : Bool = true,
      batch_size : Int32 = 100,
      max_retries : Int32 = 3,
      db_path : String? = nil,
      table_prefix : String = "memo_"
    )
      @db = db
      @owns_db = false  # Caller owns the connection
      @text_storage = store_text
      @table_prefix = table_prefix

      # Set prefix on db connection (modules read from this)
      @db.memo_table_prefix = @table_prefix

      # Get db path from pragma if not provided
      @db_path = db_path || db.query_one?(
        "SELECT file FROM pragma_database_list WHERE name = 'main'",
        as: String
      )

      Database.init(@db)

      # Initialize from service name or format
      config = init_provider(
        service: service,
        format: format,
        base_url: base_url,
        model: model,
        dimensions: dimensions,
        max_tokens: max_tokens,
        api_key: api_key,
        chunking_max_tokens: chunking_max_tokens
      )

      @provider = config.provider
      @service_id = config.service_id
      @service_name = config.service_name
      @dimensions = config.dimensions

      # Get or create projection vectors for this service
      @projection_vectors = Projection.get_projection_vectors(@db, @service_id) ||
                            create_projection_vectors(@dimensions, @service_id)

      # Create chunking config with service's tokens_per_byte ratio
      @chunking_config = Config::Chunking.new(
        min_tokens: 100,
        max_tokens: chunking_max_tokens,
        no_chunk_threshold: chunking_max_tokens,
        tokens_per_byte: config.tokens_per_byte
      )

      # Store batch size and queue config
      @batch_size = batch_size
      @queue_config = Config::Queue.new(max_retries: max_retries)
    end

    # Index a document
    #
    # Enqueues the document and processes it immediately with retry support.
    # Returns number of chunks successfully stored.
    #
    # Supports both integer and string source IDs:
    # - Int64: Time-based, sortable IDs (e.g., Unix timestamps)
    # - String: UUIDs and other text identifiers
    def index(
      source_type : String,
      source_id : ExternalId,
      text : String,
      pair_id : ExternalId? = nil,
      parent_id : ExternalId? = nil
    ) : Int32
      # Resolve external IDs to internal IDs
      internal_source_id = SourceRegistry.resolve(@db, source_type, source_id)
      internal_pair_id = if pid = pair_id
                           SourceRegistry.resolve(@db, source_type, pid)
                         else
                           nil
                         end
      internal_parent_id = if pid = parent_id
                             SourceRegistry.resolve(@db, source_type, pid)
                           else
                             nil
                           end

      enqueue_internal(
        source_type: source_type,
        internal_source_id: internal_source_id,
        text: text,
        internal_pair_id: internal_pair_id,
        internal_parent_id: internal_parent_id
      )
      process_queue_item_internal(internal_source_id)
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
    # Enqueues all documents and processes them with retry support.
    # More efficient than calling index() multiple times.
    #
    # Returns total number of documents successfully processed.
    def index_batch(docs : Array(Document)) : Int32
      return 0 if docs.empty?

      enqueue_batch(docs)
      process_queue
    end

    # Search for semantically similar chunks
    #
    # Automatically generates query embedding and searches.
    #
    # Returns array of search results ranked by similarity.
    #
    # source_id: Filter by external source ID (Int64 or String).
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
    # sql_where: Raw SQL fragment for filtering chunks. Used with ATTACH
    #   to filter by external database tables.
    #   Example: "c.source_id IN (SELECT id FROM main.artifact WHERE kind = 'goal')"
    #   Note: c.source_id here is the internal ID, not external.
    #
    # include_text: If true, includes text content in search results.
    #   Only works when text storage is enabled.
    def search(
      query : String,
      limit : Int32 = 10,
      min_score : Float64 = 0.7,
      source_type : String? = nil,
      source_id : ExternalId? = nil,
      pair_id : ExternalId? = nil,
      parent_id : ExternalId? = nil,
      like : String | Array(String) | Nil = nil,
      match : String? = nil,
      sql_where : String? = nil,
      include_text : Bool = true
    ) : Array(Search::Result)
      # Generate query embedding
      query_embedding, _tokens = @provider.embed_text(query)

      # Resolve external IDs to internal IDs for filtering
      internal_source_id = source_id && source_type ? SourceRegistry.get_internal(@db, source_type, source_id) : nil
      internal_pair_id = pair_id && source_type ? SourceRegistry.get_internal(@db, source_type, pair_id) : nil
      internal_parent_id = parent_id && source_type ? SourceRegistry.get_internal(@db, source_type, parent_id) : nil

      # Build filters with internal IDs
      filters = if source_type || internal_source_id || internal_pair_id || internal_parent_id
                  Search::Filters.new(
                    source_type: source_type,
                    internal_source_id: internal_source_id,
                    internal_pair_id: internal_pair_id,
                    internal_parent_id: internal_parent_id
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
        sql_where: sql_where,
        projection_vectors: @projection_vectors,
        like: @text_storage ? like_patterns : nil,
        match: @text_storage ? match : nil,
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
      prefix = @table_prefix

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
    # source_id: External source ID (Int64 or String).
    # source_type: Optional filter to only delete chunks with matching source_type.
    #   If nil and source_id is Int64, searches integer IDs across all types.
    #   If nil and source_id is String, searches string IDs across all types.
    def delete(source_id : ExternalId, source_type : String? = nil) : Int32
      prefix = @table_prefix

      # Resolve external ID to internal ID
      internal_id = if source_type
                      SourceRegistry.get_internal(@db, source_type, source_id)
                    else
                      SourceRegistry.get_internal_any_type(@db, source_id)
                    end

      return 0 unless internal_id

      delete_internal(internal_id, source_type)
    end

    # Delete chunks by internal source ID
    #
    # Internal method used by delete() and embed_and_store().
    private def delete_internal(internal_source_id : Int64, source_type : String? = nil) : Int32
      prefix = @table_prefix

      # Build query based on whether source_type is provided
      type_filter = source_type ? " AND source_type = ?" : ""
      query_params = source_type ? [internal_source_id, source_type] : [internal_source_id]

      # Get hashes of chunks to be deleted
      hashes = [] of Bytes
      @db.query(
        "SELECT DISTINCT hash FROM #{prefix}chunks
         WHERE source_id = ?#{type_filter}",
        args: query_params
      ) do |rs|
        rs.each do
          hashes << rs.read(Bytes)
        end
      end

      deleted_count = 0

      @db.transaction do
        # Delete chunks and count actual rows deleted
        hashes.each do |hash|
          result = if source_type
                     @db.exec(
                       "DELETE FROM #{prefix}chunks WHERE hash = ? AND source_id = ? AND source_type = ?",
                       hash, internal_source_id, source_type
                     )
                   else
                     @db.exec(
                       "DELETE FROM #{prefix}chunks WHERE hash = ? AND source_id = ?",
                       hash, internal_source_id
                     )
                   end
          deleted_count += result.rows_affected.to_i
        end

        # Clean up orphaned embeddings and projections (for ALL services)
        hashes.each do |hash|
          # Check if any chunks still reference this hash
          remaining = @db.scalar(
            "SELECT COUNT(*) FROM #{prefix}chunks WHERE hash = ?",
            hash
          ).as(Int64)

          if remaining == 0
            # No more references - delete embeddings and projections for all services
            @db.exec("DELETE FROM #{prefix}projections WHERE hash = ?", hash)
            @db.exec("DELETE FROM #{prefix}embeddings WHERE hash = ?", hash)
          end
        end

        # Clean up texts and texts_fts entries
        delete_source_text_internal(internal_source_id)
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

    # =========================================================================
    # Service Configuration CRUD
    # =========================================================================

    # Create a new service configuration
    #
    # Creates a named service configuration that can be used later with
    # Service.new(service: "name", ...).
    #
    # Example:
    # ```
    # memo.create_service(
    #   name: "azure-prod",
    #   format: "openai",
    #   base_url: "https://mycompany.openai.azure.com/",
    #   model: "text-embedding-ada-002",
    #   dimensions: 1536,
    #   max_tokens: 8191
    # )
    # ```
    def create_service(
      name : String,
      format : String,
      model : String,
      dimensions : Int32,
      max_tokens : Int32,
      base_url : String? = nil
    ) : ServiceProvider::Info
      ServiceProvider.create(@db, name, format, model, dimensions, max_tokens, base_url)
    end

    # Get a service configuration by name
    #
    # Returns nil if not found.
    def get_service(name : String) : ServiceProvider::Info?
      ServiceProvider.get_by_name(@db, name)
    end

    # List all service configurations
    #
    # Returns array of service info, ordered by creation time (newest first).
    def list_services : Array(ServiceProvider::Info)
      ServiceProvider.list(@db)
    end

    # List service configurations by format
    #
    # Returns array of service info for the specified API format.
    def list_services_by_format(format : String) : Array(ServiceProvider::Info)
      ServiceProvider.list_by_format(@db, format)
    end

    # Update a service configuration
    #
    # Can update base_url and max_tokens.
    # Returns the updated service info, or nil if not found.
    def update_service(
      name : String,
      base_url : String? = nil,
      max_tokens : Int32? = nil
    ) : ServiceProvider::Info?
      svc = ServiceProvider.get_by_name(@db, name)
      return nil unless svc
      ServiceProvider.update(@db, svc.id, base_url, max_tokens)
    end

    # Delete a service configuration
    #
    # By default, fails if the service has any associated embeddings.
    # Use force: true to delete the service and all associated data.
    #
    # Returns true if deleted, false if not found.
    def delete_service(name : String, force : Bool = false) : Bool
      svc = ServiceProvider.get_by_name(@db, name)
      return false unless svc
      ServiceProvider.delete(@db, svc.id, force)
    end

    # Get usage statistics for a service
    def service_stats(name : String) : ServiceProvider::Stats?
      svc = ServiceProvider.get_by_name(@db, name)
      return nil unless svc
      ServiceProvider.stats(@db, svc.id)
    end

    # Get the default service configuration
    def default_service : ServiceProvider::Info?
      ServiceProvider.get_default(@db)
    end

    # Set a service as the default
    #
    # Returns true if successful, false if service not found.
    def set_default_service(name : String) : Bool
      ServiceProvider.set_default(@db, name)
    end

    # Switch to a different service
    #
    # Changes the current provider and service configuration.
    # The api_key is required for non-mock services.
    #
    # Example:
    # ```
    # memo.use_service("azure-prod", api_key: ENV["AZURE_API_KEY"])
    # ```
    def use_service(name : String, api_key : String? = nil)
      svc = ServiceProvider.get_by_name(@db, name)
      raise ArgumentError.new("Service '#{name}' not found") unless svc

      # Create provider instance from stored config
      provider_instance = Providers::Registry.create(svc.format, api_key, svc.model, svc.base_url)
      raise ArgumentError.new("Unknown format: #{svc.format}") unless provider_instance

      @provider = provider_instance
      @service_name = name
      @service_id = svc.id
      @dimensions = svc.dimensions

      # Get or create projection vectors for this service
      @projection_vectors = Projection.get_projection_vectors(@db, svc.id) ||
                            create_projection_vectors(svc.dimensions, svc.id)
    end

    # =========================================================================
    # Queue Operations
    # =========================================================================

    # Queue statistics
    struct QueueStats
      getter pending : Int64
      getter failed : Int64

      def initialize(@pending, @failed)
      end
    end

    # Enqueue a document for later embedding
    #
    # Adds the document to the embed_queue table without embedding it.
    # Use process_queue to embed queued items.
    #
    # If the source is already in the queue, the text is updated.
    def enqueue(
      source_type : String,
      source_id : ExternalId,
      text : String,
      pair_id : ExternalId? = nil,
      parent_id : ExternalId? = nil
    )
      # Resolve external IDs to internal IDs
      internal_source_id = SourceRegistry.resolve(@db, source_type, source_id)
      internal_pair_id = if pid = pair_id
                           SourceRegistry.resolve(@db, source_type, pid)
                         else
                           nil
                         end
      internal_parent_id = if pid = parent_id
                             SourceRegistry.resolve(@db, source_type, pid)
                           else
                             nil
                           end

      enqueue_internal(
        source_type: source_type,
        internal_source_id: internal_source_id,
        text: text,
        internal_pair_id: internal_pair_id,
        internal_parent_id: internal_parent_id
      )
    end

    # Internal enqueue using internal source IDs
    private def enqueue_internal(
      source_type : String,
      internal_source_id : Int64,
      text : String,
      internal_pair_id : Int64? = nil,
      internal_parent_id : Int64? = nil
    )
      prefix = @table_prefix
      now = Time.utc.to_unix_ms

      # Store source_type, pair_id and parent_id in the text field as metadata prefix
      # Format: "MEMO_META:source_type,pair_id,parent_id\n" followed by actual text
      stored_text = "MEMO_META:#{source_type},#{internal_pair_id || ""},#{internal_parent_id || ""}\n#{text}"

      @db.exec(
        "INSERT INTO #{prefix}embed_queue (source_id, text, status, created_at)
         VALUES (?, ?, -1, ?)
         ON CONFLICT(source_id) DO UPDATE SET
           text = excluded.text,
           status = -1,
           error_message = NULL,
           attempts = 0,
           processed_at = NULL",
        internal_source_id, stored_text, now
      )
    end

    # Enqueue a document (Document overload)
    def enqueue(doc : Document)
      enqueue(
        source_type: doc.source_type,
        source_id: doc.source_id,
        text: doc.text,
        pair_id: doc.pair_id,
        parent_id: doc.parent_id
      )
    end

    # Enqueue multiple documents for later embedding
    #
    # More efficient than calling enqueue() multiple times.
    # Resolves all external IDs to internal IDs in a single transaction.
    def enqueue_batch(docs : Array(Document))
      return if docs.empty?

      @db.transaction do
        docs.each do |doc|
          # Resolve external IDs to internal IDs
          internal_source_id = SourceRegistry.resolve(@db, doc.source_type, doc.source_id)
          internal_pair_id = if pid = doc.pair_id
                               SourceRegistry.resolve(@db, doc.source_type, pid)
                             else
                               nil
                             end
          internal_parent_id = if pid = doc.parent_id
                                 SourceRegistry.resolve(@db, doc.source_type, pid)
                               else
                                 nil
                               end

          enqueue_internal(
            source_type: doc.source_type,
            internal_source_id: internal_source_id,
            text: doc.text,
            internal_pair_id: internal_pair_id,
            internal_parent_id: internal_parent_id
          )
        end
      end
    end

    # Process queued items
    #
    # Embeds pending items from the queue using the service's batch_size.
    # Returns number of items successfully processed.
    #
    # Failed items have their status set to the error code and can be retried
    # up to max_retries times.
    #
    # NOTE: Queue items are not atomically claimed. This is intentional -
    # single-worker processing is the expected use case since we're hitting
    # one API endpoint with batched requests. Parallel workers would hit
    # rate limits and add complexity without benefit.
    def process_queue : Int32
      prefix = @table_prefix
      max_retries = @queue_config.max_retries
      processed = 0

      loop do
        # Get a batch of pending items (source_id is internal ID)
        items = [] of {Int64, Int64, String, String, Int64?, Int64?}

        @db.query(
          "SELECT id, source_id, text FROM #{prefix}embed_queue
           WHERE status = -1
           ORDER BY created_at ASC
           LIMIT ?",
          @batch_size
        ) do |rs|
          rs.each do
            id = rs.read(Int64)
            internal_source_id = rs.read(Int64)
            stored_text = rs.read(String)

            # Parse metadata (source_type, pair_id, parent_id) from stored text
            source_type, text, pair_id, parent_id = parse_queue_text_internal(stored_text)

            items << {id, internal_source_id, source_type, text, pair_id, parent_id}
          end
        end

        break if items.empty?

        # Process each item
        items.each do |id, internal_source_id, source_type, text, pair_id, parent_id|
          begin
            # Embed and store the document
            stored = embed_and_store_internal(
              source_type: source_type,
              internal_source_id: internal_source_id,
              text: text,
              internal_pair_id: pair_id,
              internal_parent_id: parent_id
            )

            # Mark as successful
            @db.exec(
              "UPDATE #{prefix}embed_queue
               SET status = 0, processed_at = ?, attempts = attempts + 1
               WHERE id = ?",
              Time.utc.to_unix_ms, id
            )

            processed += stored

          rescue ex
            # Get current attempts
            attempts = @db.query_one(
              "SELECT attempts FROM #{prefix}embed_queue WHERE id = ?",
              id,
              as: Int32
            )

            new_attempts = attempts + 1

            if new_attempts >= max_retries
              # Max retries reached, mark as permanently failed
              @db.exec(
                "UPDATE #{prefix}embed_queue
                 SET status = 1, error_message = ?, attempts = ?, processed_at = ?
                 WHERE id = ?",
                ex.message, new_attempts, Time.utc.to_unix_ms, id
              )
            else
              # Keep as pending but increment attempts
              @db.exec(
                "UPDATE #{prefix}embed_queue
                 SET attempts = ?, error_message = ?
                 WHERE id = ?",
                new_attempts, ex.message, id
              )
            end
          end
        end
      end

      processed
    end

    # Process queued items asynchronously
    #
    # Spawns a fiber to process the queue and returns immediately.
    # Use queue_stats to check progress.
    def process_queue_async
      spawn do
        process_queue
      end
    end

    # Process a specific queued item by internal source ID
    #
    # Used by index() for immediate processing with retry support.
    # Returns number of chunks stored.
    private def process_queue_item_internal(internal_source_id : Int64) : Int32
      prefix = @table_prefix
      max_retries = @queue_config.max_retries

      # Get the specific item (using internal source_id)
      row = @db.query_one?(
        "SELECT id, text FROM #{prefix}embed_queue
         WHERE source_id = ? AND status = -1",
        internal_source_id,
        as: {Int64, String}
      )

      return 0 unless row

      id, stored_text = row
      source_type, text, pair_id, parent_id = parse_queue_text_internal(stored_text)

      attempts = 0
      last_error : Exception? = nil

      while attempts < max_retries
        begin
          chunks_stored = embed_and_store_internal(
            source_type: source_type,
            internal_source_id: internal_source_id,
            text: text,
            internal_pair_id: pair_id,
            internal_parent_id: parent_id
          )

          # Mark as successful
          @db.exec(
            "UPDATE #{prefix}embed_queue
             SET status = 0, processed_at = ?, attempts = ?
             WHERE id = ?",
            Time.utc.to_unix_ms, attempts + 1, id
          )

          return chunks_stored

        rescue ex
          last_error = ex
          attempts += 1

          @db.exec(
            "UPDATE #{prefix}embed_queue
             SET attempts = ?, error_message = ?
             WHERE id = ?",
            attempts, ex.message, id
          )
        end
      end

      # Max retries reached, mark as permanently failed
      @db.exec(
        "UPDATE #{prefix}embed_queue
         SET status = 1, error_message = ?, processed_at = ?
         WHERE id = ?",
        last_error.try(&.message), Time.utc.to_unix_ms, id
      )

      raise Exception.new("Index failed after #{max_retries} attempts: #{last_error.try(&.message)}")
    end

    # Get queue statistics
    #
    # Returns counts of pending and failed items.
    def queue_stats : QueueStats
      prefix = @table_prefix

      pending = @db.scalar(
        "SELECT COUNT(*) FROM #{prefix}embed_queue WHERE status = -1",
      ).as(Int64)

      failed = @db.scalar(
        "SELECT COUNT(*) FROM #{prefix}embed_queue WHERE status > 0",
      ).as(Int64)

      QueueStats.new(pending, failed)
    end

    # Clear completed items from the queue
    #
    # Removes successfully processed items (status = 0).
    # Returns number of items removed.
    def clear_completed_queue : Int32
      prefix = @table_prefix

      result = @db.exec(
        "DELETE FROM #{prefix}embed_queue WHERE status = 0"
      )

      result.rows_affected.to_i
    end

    # Clear all items from the queue
    #
    # Removes all items regardless of status.
    # Returns number of items removed.
    def clear_queue : Int32
      prefix = @table_prefix

      result = @db.exec(
        "DELETE FROM #{prefix}embed_queue"
      )

      result.rows_affected.to_i
    end

    # Re-index all content of a given source type
    #
    # Deletes existing embeddings and queues text for re-embedding.
    # Requires text storage to be enabled.
    #
    # Returns number of items queued for re-indexing.
    def reindex(source_type : String) : Int32
      raise "Text storage required for reindex without block" unless @text_storage

      prefix = @table_prefix
      queued = 0

      # Get source texts and metadata from chunks table
      # texts stores full content (keyed by internal source_id), chunks has metadata
      # Join through sources to get only sources of the requested type
      sources = [] of {Int64, Int64?, Int64?, String}

      @db.query(
        "SELECT st.source_id, c.pair_id, c.parent_id, st.content
         FROM #{prefix}texts st
         JOIN #{prefix}sources s ON st.source_id = s.id
         LEFT JOIN #{prefix}chunks c ON st.source_id = c.source_id
         WHERE s.source_type = ?
         GROUP BY st.source_id",
        source_type
      ) do |rs|
        rs.each do
          internal_source_id = rs.read(Int64)
          pair_id = rs.read(Int64?)
          parent_id = rs.read(Int64?)
          text = rs.read(String)
          sources << {internal_source_id, pair_id, parent_id, text}
        end
      end

      return 0 if sources.empty?

      @db.transaction do
        # Delete existing chunks and embeddings for this source type
        # (orphan cleanup will handle embeddings not referenced elsewhere)
        sources.each do |internal_source_id, _, _, _|
          delete_internal(internal_source_id, source_type)
        end

        # Queue for re-embedding using internal IDs
        sources.each do |internal_source_id, pair_id, parent_id, text|
          enqueue_internal(
            source_type: source_type,
            internal_source_id: internal_source_id,
            text: text,
            internal_pair_id: pair_id,
            internal_parent_id: parent_id
          )
          queued += 1
        end
      end

      queued
    end

    # Re-index all content of a given source type using a block to fetch text
    #
    # Use this when text storage is disabled. The block receives the external
    # source_id and should return the text to embed.
    #
    # Returns number of items queued for re-indexing.
    #
    # Example:
    # ```
    # memo.reindex("article") do |source_id|
    #   app.get_article_text(source_id)
    # end
    # memo.process_queue
    # ```
    def reindex(source_type : String, &block : ExternalId -> String) : Int32
      prefix = @table_prefix
      queued = 0

      # Get all internal source_ids and metadata for this source type
      # plus external IDs for the callback
      sources = [] of {Int64, ExternalId, Int64?, Int64?}

      @db.query(
        "SELECT DISTINCT c.source_id, s.external_int, s.external_text, c.pair_id, c.parent_id
         FROM #{prefix}chunks c
         JOIN #{prefix}embeddings e ON c.hash = e.hash
         JOIN #{prefix}sources s ON c.source_id = s.id
         WHERE c.source_type = ? AND e.service_id = ?",
        source_type, @service_id
      ) do |rs|
        rs.each do
          internal_source_id = rs.read(Int64)
          external_int = rs.read(Int64?)
          external_text = rs.read(String?)
          pair_id = rs.read(Int64?)
          parent_id = rs.read(Int64?)
          external_id : ExternalId = external_int || external_text.not_nil!
          sources << {internal_source_id, external_id, pair_id, parent_id}
        end
      end

      return 0 if sources.empty?

      @db.transaction do
        # Delete existing chunks and embeddings
        sources.each do |internal_source_id, _, _, _|
          delete_internal(internal_source_id, source_type)
        end

        # Queue for re-embedding using block to get text (passes external ID)
        sources.each do |internal_source_id, external_id, pair_id, parent_id|
          text = block.call(external_id)
          enqueue_internal(
            source_type: source_type,
            internal_source_id: internal_source_id,
            text: text,
            internal_pair_id: pair_id,
            internal_parent_id: parent_id
          )
          queued += 1
        end
      end

      queued
    end

    # Initialize provider from service name, format parameters, or default
    #
    # Priority:
    # 1. If service name is provided, looks up the configuration from the database
    # 2. If format is provided, creates inline configuration
    # 3. Otherwise, uses the default service
    #
    # Returns ProviderConfig with provider instance and service metadata
    private def init_provider(
      service : String?,
      format : String?,
      base_url : String?,
      model : String?,
      dimensions : Int32?,
      max_tokens : Int32?,
      api_key : String?,
      chunking_max_tokens : Int32
    ) : ProviderConfig
      if service
        # Look up existing service configuration by name
        svc = Storage.get_service_by_name(@db, service)
        raise ArgumentError.new("Service '#{service}' not found") unless svc

        svc_id, svc_format, svc_base_url, svc_model, svc_dimensions, svc_max_tokens, svc_tokens_per_byte = svc

        # Create provider instance from stored config
        provider_instance = Providers::Registry.create(svc_format, api_key, svc_model, svc_base_url)
        raise ArgumentError.new("Unknown format: #{svc_format}") unless provider_instance

        # Validate chunking doesn't exceed provider limits
        if chunking_max_tokens > svc_max_tokens
          raise ArgumentError.new("chunking_max_tokens (#{chunking_max_tokens}) exceeds service limit (#{svc_max_tokens})")
        end

        ProviderConfig.new(provider_instance, svc_id, service, svc_dimensions, svc_max_tokens, svc_tokens_per_byte)
      elsif format
        # Configure inline from format parameters
        final_format = format

        # Try to find existing service by format/model
        if model
          existing = Storage.get_service_by_format_model(@db, final_format, model)
        end

        if existing
          # Use existing service configuration
          # Don't allow overriding dimensions - it's intrinsic to the model
          # and overriding would cause projection vector dimension mismatch
          _id, _fmt, _base_url, svc_model, svc_dimensions, svc_max_tokens, svc_tokens_per_byte = existing
          if dimensions && dimensions != svc_dimensions
            raise ArgumentError.new("Cannot override dimensions (#{dimensions}) for existing service with dimensions=#{svc_dimensions}")
          end
          final_model = svc_model
          final_dimensions = svc_dimensions
          # max_tokens can be overridden - it's a limit we choose, not intrinsic to model
          final_max_tokens = max_tokens || svc_max_tokens
          final_tokens_per_byte = svc_tokens_per_byte
        else
          # No existing service - require all parameters
          raise ArgumentError.new("model required for format: #{final_format}") unless model
          raise ArgumentError.new("dimensions required for #{final_format}/#{model}") unless dimensions
          raise ArgumentError.new("max_tokens required for #{final_format}/#{model}") unless max_tokens
          final_model = model
          final_dimensions = dimensions
          final_max_tokens = max_tokens
          final_tokens_per_byte = 0.25
        end

        # Validate chunking doesn't exceed provider limits
        if chunking_max_tokens > final_max_tokens
          raise ArgumentError.new("chunking_max_tokens (#{chunking_max_tokens}) exceeds provider limit (#{final_max_tokens})")
        end

        # Create provider instance
        provider_instance = Providers::Registry.create(final_format, api_key, final_model, base_url)
        raise ArgumentError.new("Unknown format: #{final_format}") unless provider_instance

        # Register or get existing service in database (auto-generates name)
        service_id = Storage.register_service(
          db: @db,
          name: nil,  # Auto-generate from format/model
          format: final_format,
          base_url: base_url,
          model: final_model,
          dimensions: final_dimensions,
          max_tokens: final_max_tokens
        )

        ProviderConfig.new(provider_instance, service_id, "#{final_format}/#{final_model}", final_dimensions, final_max_tokens, final_tokens_per_byte)
      else
        # Use the default service
        default_svc = ServiceProvider.get_default(@db)
        raise ArgumentError.new("No default service configured") unless default_svc

        # Create provider instance from default service config
        provider_instance = Providers::Registry.create(default_svc.format, api_key, default_svc.model, default_svc.base_url)
        raise ArgumentError.new("Unknown format: #{default_svc.format}") unless provider_instance

        # Validate chunking doesn't exceed provider limits
        if chunking_max_tokens > default_svc.max_tokens
          raise ArgumentError.new("chunking_max_tokens (#{chunking_max_tokens}) exceeds service limit (#{default_svc.max_tokens})")
        end

        ProviderConfig.new(provider_instance, default_svc.id, default_svc.name, default_svc.dimensions, default_svc.max_tokens, default_svc.tokens_per_byte)
      end
    end

    # Generate and store projection vectors for this service
    private def create_projection_vectors(dimensions : Int32, service_id : Int64) : Array(Array(Float64))
      vectors = Projection.generate_orthogonal_vectors(dimensions)
      Projection.store_projection_vectors(@db, service_id, vectors)
      vectors
    end

    # Store source text (keyed by internal source_id)
    # Also populates FTS5 index for full-text search
    #
    # Stores the original un-chunked text. Chunk text is extracted
    # using offset/size from the chunks table.
    private def store_source_text_internal(internal_source_id : Int64, content : String)
      prefix = @table_prefix
      now = Time.utc.to_unix_ms

      # Insert or replace source text (keyed by internal source_id)
      @db.exec(
        "INSERT OR REPLACE INTO #{prefix}texts (source_id, content, created_at)
         VALUES (?, ?, ?)",
        internal_source_id, content, now
      )

      # Update FTS5 index
      # Delete any existing entry first (FTS5 doesn't support INSERT OR REPLACE)
      @db.exec(
        "DELETE FROM #{prefix}texts_fts WHERE source_id = ?",
        internal_source_id
      )
      @db.exec(
        "INSERT INTO #{prefix}texts_fts (source_id, content)
         VALUES (?, ?)",
        internal_source_id, content
      )
    end

    # Delete source text by internal ID
    private def delete_source_text_internal(internal_source_id : Int64)
      prefix = @table_prefix
      @db.exec(
        "DELETE FROM #{prefix}texts WHERE source_id = ?",
        internal_source_id
      )
      @db.exec(
        "DELETE FROM #{prefix}texts_fts WHERE source_id = ?",
        internal_source_id
      )
    end

    # Get source text by internal source_id
    private def get_source_text_internal(internal_source_id : Int64) : String?
      prefix = @table_prefix
      @db.query_one?(
        "SELECT content FROM #{prefix}texts WHERE source_id = ?",
        internal_source_id,
        as: String
      )
    end

    # Parse queue text to extract metadata and actual text (internal format)
    #
    # Format: "MEMO_META:source_type,pair_id,parent_id\n" followed by actual text
    # Returns {source_type, text, internal_pair_id, internal_parent_id}
    private def parse_queue_text_internal(stored_text : String) : {String, String, Int64?, Int64?}
      if stored_text.starts_with?("MEMO_META:")
        newline_idx = stored_text.index('\n')
        if newline_idx
          meta_line = stored_text[10...newline_idx]
          text = stored_text[(newline_idx + 1)..]

          parts = meta_line.split(',', 3)
          source_type = parts[0]
          pair_id = parts.size > 1 && !parts[1].empty? ? parts[1].to_i64 : nil
          parent_id = parts.size > 2 && !parts[2].empty? ? parts[2].to_i64 : nil

          {source_type, text, pair_id, parent_id}
        else
          # Malformed - no newline
          {"unknown", stored_text, nil, nil}
        end
      else
        # No metadata prefix - legacy format, shouldn't happen with new code
        {"unknown", stored_text, nil, nil}
      end
    end

    # Core embedding logic - chunks, embeds, and stores a document
    #
    # This is the internal implementation used by both process_queue and
    # process_queue_item. It does not interact with the queue table.
    #
    # All IDs are internal (FK to sources table).
    #
    # Deletes existing chunks for the source before re-indexing to ensure
    # clean state if chunking settings have changed.
    #
    # TODO: Consider storing source text hash to skip re-indexing unchanged content
    #
    # Returns number of chunks successfully stored.
    private def embed_and_store_internal(
      source_type : String,
      internal_source_id : Int64,
      text : String,
      internal_pair_id : Int64? = nil,
      internal_parent_id : Int64? = nil
    ) : Int32
      # Chunk text (returns tuples of {text, offset, size})
      chunks = Chunking.chunk_text(text, @chunking_config)
      return 0 if chunks.empty?

      # Extract just the text for embedding
      chunk_texts = chunks.map { |(chunk_text, _, _)| chunk_text }

      # Embed chunks (API call - outside transaction so failure is safe)
      embed_result = @provider.embed_texts(chunk_texts)

      # Update tokens_per_byte ratio based on actual API results
      total_bytes = chunk_texts.sum(&.bytesize)
      if total_bytes > 0 && embed_result.total_tokens > 0
        observed_ratio = embed_result.total_tokens.to_f / total_bytes
        Storage.update_tokens_per_byte(@db, @service_id, observed_ratio)

        # Also update in-memory config so future chunking uses the new ratio
        # (Storage.update_tokens_per_byte uses EMA, so fetch the actual updated value)
        updated_ratio = @db.query_one?(
          "SELECT tokens_per_byte FROM #{@table_prefix}services WHERE id = ?",
          @service_id, as: Float64
        )
        @chunking_config = @chunking_config.with_tokens_per_byte(updated_ratio) if updated_ratio
      end

      # Delete old and store new atomically
      success_count = 0

      @db.transaction do
        # Delete existing chunks for this source before storing new ones
        # This ensures clean state if chunking settings have changed
        delete_internal(internal_source_id, source_type)

        # Store source text once (not per-chunk)
        # Chunk text is extracted using offset/size when needed
        store_source_text_internal(internal_source_id, text) if @text_storage

        chunks.each_with_index do |(chunk_text, offset, size), idx|
          hash = Storage.compute_hash(chunk_text)
          embedding = embed_result.embeddings[idx]
          token_count = embed_result.token_counts[idx]

          # Store embedding (deduplicated by hash)
          Storage.store_embedding(@db, hash, embedding, token_count, @service_id)

          # Compute and store projections for fast filtering (per service)
          projections = Projection.compute_projections(embedding, @projection_vectors)
          Projection.store_projections(@db, hash, @service_id, projections)

          # Create chunk reference with offset/size from chunking
          # All IDs are internal (FK to sources table)
          chunk_id = Storage.create_chunk(
            db: @db,
            hash: hash,
            source_type: source_type,
            source_id: internal_source_id,
            offset: offset,
            size: size,
            pair_id: internal_pair_id,
            parent_id: internal_parent_id
          )

          # Only count if chunk was actually inserted (not ignored as duplicate)
          success_count += 1 if chunk_id > 0
        end
      end

      success_count
    end
  end
end
