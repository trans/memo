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
  # ## Quick Start
  #
  # ```
  # # Initialize with default OpenAI format
  # memo = Memo::Service.new(
  #   data_dir: "/var/data/memo",
  #   format: "openai",
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
  # ## Service Configuration
  #
  # For custom endpoints (Azure, local LLMs, etc.), create named service configs:
  #
  # ```
  # # First, initialize memo (e.g., with mock for setup)
  # memo = Memo::Service.new(data_dir: "/var/data/memo", format: "mock")
  #
  # # Create a service configuration
  # memo.create_service(
  #   name: "azure-prod",
  #   format: "openai",
  #   base_url: "https://mycompany.openai.azure.com/",
  #   model: "text-embedding-ada-002",
  #   dimensions: 1536,
  #   max_tokens: 8191
  # )
  #
  # # Later, use the service by name
  # memo2 = Memo::Service.new(
  #   data_dir: "/var/data/memo",
  #   service: "azure-prod",
  #   api_key: ENV["AZURE_API_KEY"]
  # )
  # ```
  #
  # ## Database Files
  #
  # Memo stores data in the specified directory:
  # - embeddings.db: Embeddings, chunks, projections (regenerable)
  # - text.db: Text content (persistent)
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
    getter data_dir : String?

    # Schema name for ATTACHed text database
    TEXT_SCHEMA = "text_store"

    # Track whether we own the db connection (for close behavior)
    @owns_db : Bool = true

    # Track whether text storage is enabled
    getter? text_storage : Bool = false

    # Initialize service with data directory
    #
    # Use EITHER:
    # - service: Name of pre-configured service (from ServiceProvider.create)
    # - format: API format ("openai", "mock") to configure inline
    #
    # Required:
    # - data_dir: Directory path for database files
    # - api_key: API key (not needed for mock format)
    #
    # Optional:
    # - service: Name of pre-configured service to use
    # - format: API format for inline configuration (default "openai")
    # - base_url: Custom API endpoint (for OpenAI-compatible APIs)
    # - model: Embedding model (default depends on format)
    # - dimensions: Vector dimensions (auto-detected from model)
    # - max_tokens: Token limit (auto-detected from model)
    # - store_text: Enable text storage in text.db (default true)
    # - attach: Hash of alias => path for databases to ATTACH
    # - chunking_max_tokens: Max tokens per chunk (default 2000)
    #
    # Example with pre-configured service:
    # ```
    # # First, create a service configuration
    # ServiceProvider.create(db, name: "azure", format: "openai",
    #   base_url: "https://mycompany.openai.azure.com/",
    #   model: "text-embedding-ada-002", dimensions: 1536, max_tokens: 8191)
    #
    # # Then use it by name
    # memo = Memo::Service.new(
    #   data_dir: "/var/data/memo",
    #   service: "azure",
    #   api_key: ENV["AZURE_API_KEY"]
    # )
    # ```
    def initialize(
      data_dir : String,
      api_key : String? = nil,
      service : String? = nil,
      format : String? = nil,
      base_url : String? = nil,
      model : String? = nil,
      dimensions : Int32? = nil,
      max_tokens : Int32? = nil,
      chunking_max_tokens : Int32 = 2000,
      store_text : Bool = true,
      attach : Hash(String, String)? = nil,
      batch_size : Int32 = 100,
      max_retries : Int32 = 3
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

      # Initialize from service name or format
      init_provider(
        service: service,
        format: format,
        base_url: base_url,
        model: model,
        dimensions: dimensions,
        max_tokens: max_tokens,
        api_key: api_key,
        chunking_max_tokens: chunking_max_tokens
      )

      # Store batch size and queue config
      @batch_size = batch_size
      @queue_config = Config::Queue.new(max_retries: max_retries)
    end

    # Initialize service with existing database connection
    #
    # Use this when caller manages the connection lifecycle.
    # Caller is responsible for closing the connection.
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
      batch_size : Int32 = 100,
      max_retries : Int32 = 3
    )
      @db = db
      @data_dir = nil  # No data directory when using external connection
      @owns_db = false  # Caller owns the connection
      Database.init(@db)

      # Standalone mode - no table prefix
      Memo.table_prefix = ""

      # Initialize from service name or format
      init_provider(
        service: service,
        format: format,
        base_url: base_url,
        model: model,
        dimensions: dimensions,
        max_tokens: max_tokens,
        api_key: api_key,
        chunking_max_tokens: chunking_max_tokens
      )

      # Store batch size and queue config
      @batch_size = batch_size
      @queue_config = Config::Queue.new(max_retries: max_retries)
    end

    # Index a document
    #
    # Enqueues the document and processes it immediately with retry support.
    # Returns number of chunks successfully stored.
    def index(
      source_type : String,
      source_id : Int64,
      text : String,
      pair_id : Int64? = nil,
      parent_id : Int64? = nil
    ) : Int32
      enqueue(
        source_type: source_type,
        source_id: source_id,
        text: text,
        pair_id: pair_id,
        parent_id: parent_id
      )
      process_queue_item(source_type, source_id)
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
      sql_where : String? = nil,
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
        sql_where: sql_where,
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
      source_id : Int64,
      text : String,
      pair_id : Int64? = nil,
      parent_id : Int64? = nil
    )
      prefix = Memo.table_prefix
      now = Time.utc.to_unix_ms

      # Store pair_id and parent_id in the text field as metadata prefix
      # Format: "MEMO_META:pair_id,parent_id\n" followed by actual text
      stored_text = if pair_id || parent_id
                      "MEMO_META:#{pair_id || ""},#{parent_id || ""}\n#{text}"
                    else
                      text
                    end

      @db.exec(
        "INSERT INTO #{prefix}embed_queue (source_type, source_id, text, status, created_at)
         VALUES (?, ?, ?, -1, ?)
         ON CONFLICT(source_type, source_id) DO UPDATE SET
           text = excluded.text,
           status = -1,
           error_message = NULL,
           attempts = 0,
           processed_at = NULL",
        source_type, source_id, stored_text, now
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
    def enqueue_batch(docs : Array(Document))
      return if docs.empty?

      @db.transaction do
        docs.each do |doc|
          enqueue(doc)
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
    def process_queue : Int32
      prefix = Memo.table_prefix
      max_retries = @queue_config.max_retries
      processed = 0

      loop do
        # Get a batch of pending items
        items = [] of {Int64, String, Int64, String, Int64?, Int64?}

        @db.query(
          "SELECT id, source_type, source_id, text FROM #{prefix}embed_queue
           WHERE status = -1
           ORDER BY created_at ASC
           LIMIT ?",
          @batch_size
        ) do |rs|
          rs.each do
            id = rs.read(Int64)
            source_type = rs.read(String)
            source_id = rs.read(Int64)
            stored_text = rs.read(String)

            # Parse metadata if present
            text, pair_id, parent_id = parse_queue_text(stored_text)

            items << {id, source_type, source_id, text, pair_id, parent_id}
          end
        end

        break if items.empty?

        # Process each item
        items.each do |id, source_type, source_id, text, pair_id, parent_id|
          begin
            # Embed and store the document
            embed_and_store(
              source_type: source_type,
              source_id: source_id,
              text: text,
              pair_id: pair_id,
              parent_id: parent_id
            )

            # Mark as successful
            @db.exec(
              "UPDATE #{prefix}embed_queue
               SET status = 0, processed_at = ?, attempts = attempts + 1
               WHERE id = ?",
              Time.utc.to_unix_ms, id
            )

            processed += 1

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

    # Process a specific queued item
    #
    # Used by index() for immediate processing with retry support.
    # Returns number of chunks stored.
    def process_queue_item(source_type : String, source_id : Int64) : Int32
      prefix = Memo.table_prefix
      max_retries = @queue_config.max_retries

      # Get the specific item
      row = @db.query_one?(
        "SELECT id, text FROM #{prefix}embed_queue
         WHERE source_type = ? AND source_id = ? AND status = -1",
        source_type, source_id,
        as: {Int64, String}
      )

      return 0 unless row

      id, stored_text = row
      text, pair_id, parent_id = parse_queue_text(stored_text)

      attempts = 0
      last_error : Exception? = nil

      while attempts < max_retries
        begin
          chunks_stored = embed_and_store(
            source_type: source_type,
            source_id: source_id,
            text: text,
            pair_id: pair_id,
            parent_id: parent_id
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
      prefix = Memo.table_prefix

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
      prefix = Memo.table_prefix

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
      prefix = Memo.table_prefix

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

      prefix = Memo.table_prefix
      queued = 0

      # Get all chunks of this source type with their text
      chunks = [] of {Int64, Int64?, Int64?, String}

      @db.query(
        "SELECT c.source_id, c.pair_id, c.parent_id, t.content
         FROM #{prefix}chunks c
         JOIN #{prefix}embeddings e ON c.hash = e.hash
         JOIN #{TEXT_SCHEMA}.texts t ON c.hash = t.hash
         WHERE c.source_type = ? AND e.service_id = ?
         GROUP BY c.source_id",
        source_type, @service_id
      ) do |rs|
        rs.each do
          source_id = rs.read(Int64)
          pair_id = rs.read(Int64?)
          parent_id = rs.read(Int64?)
          text = rs.read(String)
          chunks << {source_id, pair_id, parent_id, text}
        end
      end

      return 0 if chunks.empty?

      @db.transaction do
        # Delete existing chunks and embeddings for this source type
        # (orphan cleanup will handle embeddings not referenced elsewhere)
        source_ids = chunks.map { |c| c[0] }.uniq

        source_ids.each do |source_id|
          delete(source_id, source_type)
        end

        # Queue for re-embedding
        chunks.each do |source_id, pair_id, parent_id, text|
          enqueue(
            source_type: source_type,
            source_id: source_id,
            text: text,
            pair_id: pair_id,
            parent_id: parent_id
          )
          queued += 1
        end
      end

      queued
    end

    # Re-index all content of a given source type using a block to fetch text
    #
    # Use this when text storage is disabled. The block receives each source_id
    # and should return the text to embed.
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
    def reindex(source_type : String, &block : Int64 -> String) : Int32
      prefix = Memo.table_prefix
      queued = 0

      # Get all source_ids and metadata for this source type
      sources = [] of {Int64, Int64?, Int64?}

      @db.query(
        "SELECT DISTINCT c.source_id, c.pair_id, c.parent_id
         FROM #{prefix}chunks c
         JOIN #{prefix}embeddings e ON c.hash = e.hash
         WHERE c.source_type = ? AND e.service_id = ?",
        source_type, @service_id
      ) do |rs|
        rs.each do
          source_id = rs.read(Int64)
          pair_id = rs.read(Int64?)
          parent_id = rs.read(Int64?)
          sources << {source_id, pair_id, parent_id}
        end
      end

      return 0 if sources.empty?

      @db.transaction do
        # Delete existing chunks and embeddings
        sources.each do |source_id, _, _|
          delete(source_id, source_type)
        end

        # Queue for re-embedding using block to get text
        sources.each do |source_id, pair_id, parent_id|
          text = block.call(source_id)
          enqueue(
            source_type: source_type,
            source_id: source_id,
            text: text,
            pair_id: pair_id,
            parent_id: parent_id
          )
          queued += 1
        end
      end

      queued
    end

    # Initialize provider from service name or format parameters
    #
    # If service name is provided, looks up the configuration from the database.
    # Otherwise, creates a new configuration from the provided format/model/etc.
    private def init_provider(
      service : String?,
      format : String?,
      base_url : String?,
      model : String?,
      dimensions : Int32?,
      max_tokens : Int32?,
      api_key : String?,
      chunking_max_tokens : Int32
    )
      if service
        # Look up existing service configuration by name
        svc = Storage.get_service_by_name(@db, service)
        raise ArgumentError.new("Service '#{service}' not found") unless svc

        svc_id, svc_format, svc_base_url, svc_model, svc_dimensions, svc_max_tokens = svc

        @service_name = service
        @service_id = svc_id
        @dimensions = svc_dimensions

        # Create provider instance from stored config
        provider_instance = Providers::Registry.create(svc_format, api_key, svc_model, svc_base_url)
        raise ArgumentError.new("Unknown format: #{svc_format}") unless provider_instance
        @provider = provider_instance

        # Validate chunking doesn't exceed provider limits
        if chunking_max_tokens > svc_max_tokens
          raise ArgumentError.new("chunking_max_tokens (#{chunking_max_tokens}) exceeds service limit (#{svc_max_tokens})")
        end

        final_max_tokens = svc_max_tokens
      else
        # Configure inline from format parameters
        final_format = format || "openai"

        # Validate format is supported
        unless Providers::Registry.format?(final_format)
          raise ArgumentError.new("Unknown format: #{final_format}")
        end

        # Auto-detect model, dimensions, and max_tokens from registry
        final_model = model || Providers::Registry.default_model(final_format) || raise ArgumentError.new("No default model for format: #{final_format}")
        final_dimensions = dimensions || Providers::Registry.dimensions(final_format, final_model) || raise ArgumentError.new("Unknown dimensions for #{final_format}/#{final_model}")
        final_max_tokens = max_tokens || Providers::Registry.max_tokens(final_format, final_model) || raise ArgumentError.new("Unknown max_tokens for #{final_format}/#{final_model}")

        # Validate chunking doesn't exceed provider limits
        if chunking_max_tokens > final_max_tokens
          raise ArgumentError.new("chunking_max_tokens (#{chunking_max_tokens}) exceeds provider limit (#{final_max_tokens})")
        end

        @dimensions = final_dimensions

        # Create provider instance
        provider_instance = Providers::Registry.create(final_format, api_key, final_model, base_url)
        raise ArgumentError.new("Failed to create provider for format: #{final_format}") unless provider_instance
        @provider = provider_instance

        # Register or get existing service in database (auto-generates name)
        @service_id = Storage.register_service(
          db: @db,
          name: nil,  # Auto-generate from format/model
          format: final_format,
          base_url: base_url,
          model: final_model,
          dimensions: final_dimensions,
          max_tokens: final_max_tokens
        )

        @service_name = "#{final_format}/#{final_model}"
      end

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

    # Parse queue text to extract metadata and actual text
    #
    # Format: "MEMO_META:pair_id,parent_id\n" followed by actual text
    # Returns {text, pair_id, parent_id}
    private def parse_queue_text(stored_text : String) : {String, Int64?, Int64?}
      if stored_text.starts_with?("MEMO_META:")
        newline_idx = stored_text.index('\n')
        if newline_idx
          meta_line = stored_text[10...newline_idx]
          text = stored_text[(newline_idx + 1)..]

          parts = meta_line.split(',', 2)
          pair_id = parts[0].empty? ? nil : parts[0].to_i64
          parent_id = parts.size > 1 && !parts[1].empty? ? parts[1].to_i64 : nil

          {text, pair_id, parent_id}
        else
          {stored_text, nil, nil}
        end
      else
        {stored_text, nil, nil}
      end
    end

    # Core embedding logic - chunks, embeds, and stores a document
    #
    # This is the internal implementation used by both process_queue and
    # process_queue_item. It does not interact with the queue table.
    #
    # Returns number of chunks successfully stored.
    private def embed_and_store(
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
    end
  end
end
