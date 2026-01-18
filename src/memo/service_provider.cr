module Memo
  # Public CRUD interface for service provider configurations
  #
  # Manages the services table which tracks provider/model combinations
  # and their configurations. Each service represents a unique embedding
  # configuration that embeddings are associated with.
  #
  # ## Usage
  #
  # ```
  # db = DB.open("sqlite3://embeddings.db")
  # Memo::Database.init(db)
  #
  # # Create a new service configuration
  # service = Memo::ServiceProvider.create(
  #   db: db,
  #   provider: "openai",
  #   model: "text-embedding-3-small",
  #   dimensions: 1536,
  #   max_tokens: 8191
  # )
  #
  # # List all services
  # services = Memo::ServiceProvider.list(db)
  #
  # # Get a specific service
  # service = Memo::ServiceProvider.get(db, id: 1)
  #
  # # Delete a service (fails if embeddings exist)
  # Memo::ServiceProvider.delete(db, id: 1)
  #
  # # Force delete with all associated data
  # Memo::ServiceProvider.delete(db, id: 1, force: true)
  # ```
  module ServiceProvider
    # Service configuration information
    struct Info
      getter id : Int64
      getter provider : String
      getter model : String
      getter version : String?
      getter dimensions : Int32
      getter max_tokens : Int32
      getter created_at : Time

      def initialize(
        @id : Int64,
        @provider : String,
        @model : String,
        @version : String?,
        @dimensions : Int32,
        @max_tokens : Int32,
        @created_at : Time
      )
      end
    end

    # Statistics about a service's usage
    struct Stats
      getter embeddings : Int64
      getter chunks : Int64

      def initialize(@embeddings : Int64, @chunks : Int64)
      end

      def empty? : Bool
        @embeddings == 0 && @chunks == 0
      end
    end

    extend self

    # Create a new service configuration
    #
    # If a service with the same provider/model/version/dimensions already exists,
    # returns the existing service.
    #
    # Returns the created or existing service info.
    def create(
      db : DB::Database,
      provider : String,
      model : String,
      dimensions : Int32,
      max_tokens : Int32,
      version : String? = nil
    ) : Info
      prefix = Memo.table_prefix

      # Check if already exists
      existing = get_by_config(db, provider, model, version, dimensions)
      return existing if existing

      # Insert new service
      now = Time.utc
      db.exec(
        "INSERT INTO #{prefix}services (provider, model, version, dimensions, max_tokens, created_at)
         VALUES (?, ?, ?, ?, ?, ?)",
        provider, model, version, dimensions, max_tokens, now.to_unix_ms
      )

      id = db.scalar("SELECT last_insert_rowid()").as(Int64)

      Info.new(
        id: id,
        provider: provider,
        model: model,
        version: version,
        dimensions: dimensions,
        max_tokens: max_tokens,
        created_at: now
      )
    end

    # Get a service by ID
    #
    # Returns nil if not found.
    def get(db : DB::Database, id : Int64) : Info?
      prefix = Memo.table_prefix

      db.query_one?(
        "SELECT id, provider, model, version, dimensions, max_tokens, created_at
         FROM #{prefix}services WHERE id = ?",
        id
      ) do |rs|
        read_info(rs)
      end
    end

    # Get a service by its configuration
    #
    # Returns nil if not found.
    def get_by_config(
      db : DB::Database,
      provider : String,
      model : String,
      version : String?,
      dimensions : Int32
    ) : Info?
      prefix = Memo.table_prefix

      db.query_one?(
        "SELECT id, provider, model, version, dimensions, max_tokens, created_at
         FROM #{prefix}services
         WHERE provider = ? AND model = ? AND version IS ? AND dimensions = ?",
        provider, model, version, dimensions
      ) do |rs|
        read_info(rs)
      end
    end

    # List all services
    #
    # Returns array of service info, ordered by creation time (newest first).
    def list(db : DB::Database) : Array(Info)
      prefix = Memo.table_prefix
      services = [] of Info

      db.query(
        "SELECT id, provider, model, version, dimensions, max_tokens, created_at
         FROM #{prefix}services
         ORDER BY created_at DESC"
      ) do |rs|
        rs.each do
          services << read_info(rs)
        end
      end

      services
    end

    # List services by provider
    #
    # Returns array of service info for the specified provider.
    def list_by_provider(db : DB::Database, provider : String) : Array(Info)
      prefix = Memo.table_prefix
      services = [] of Info

      db.query(
        "SELECT id, provider, model, version, dimensions, max_tokens, created_at
         FROM #{prefix}services
         WHERE provider = ?
         ORDER BY created_at DESC",
        provider
      ) do |rs|
        rs.each do
          services << read_info(rs)
        end
      end

      services
    end

    # Update a service's max_tokens
    #
    # Only max_tokens can be updated as other fields define the service identity.
    # Returns the updated service info, or nil if not found.
    def update(db : DB::Database, id : Int64, max_tokens : Int32) : Info?
      prefix = Memo.table_prefix

      result = db.exec(
        "UPDATE #{prefix}services SET max_tokens = ? WHERE id = ?",
        max_tokens, id
      )

      return nil if result.rows_affected == 0

      get(db, id)
    end

    # Delete a service
    #
    # By default, fails if the service has any associated embeddings.
    # Use force: true to delete the service and all associated data.
    #
    # Returns true if deleted, false if not found.
    # Raises if embeddings exist and force is false.
    def delete(db : DB::Database, id : Int64, force : Bool = false) : Bool
      prefix = Memo.table_prefix

      # Check if service exists
      return false unless get(db, id)

      # Check for associated embeddings
      stats = stats(db, id)

      if !stats.empty? && !force
        raise ArgumentError.new(
          "Cannot delete service #{id}: has #{stats.embeddings} embeddings and #{stats.chunks} chunks. " \
          "Use force: true to delete all associated data."
        )
      end

      db.transaction do
        if force && !stats.empty?
          # Delete in order: chunks -> projections -> embeddings -> projection_vectors -> service
          # Get all embedding hashes for this service
          hashes = [] of Bytes
          db.query(
            "SELECT hash FROM #{prefix}embeddings WHERE service_id = ?",
            id
          ) do |rs|
            rs.each do
              hashes << rs.read(Bytes)
            end
          end

          # Delete chunks referencing these embeddings
          hashes.each do |hash|
            db.exec("DELETE FROM #{prefix}chunks WHERE hash = ?", hash)
            db.exec("DELETE FROM #{prefix}projections WHERE hash = ?", hash)
          end

          # Delete embeddings
          db.exec("DELETE FROM #{prefix}embeddings WHERE service_id = ?", id)

          # Delete projection vectors
          db.exec("DELETE FROM #{prefix}projection_vectors WHERE service_id = ?", id)
        end

        # Delete the service
        db.exec("DELETE FROM #{prefix}services WHERE id = ?", id)
      end

      true
    end

    # Get usage statistics for a service
    def stats(db : DB::Database, id : Int64) : Stats
      prefix = Memo.table_prefix

      embeddings = db.scalar(
        "SELECT COUNT(*) FROM #{prefix}embeddings WHERE service_id = ?",
        id
      ).as(Int64)

      chunks = db.scalar(
        "SELECT COUNT(*) FROM #{prefix}chunks c
         JOIN #{prefix}embeddings e ON c.hash = e.hash
         WHERE e.service_id = ?",
        id
      ).as(Int64)

      Stats.new(embeddings, chunks)
    end

    # Check if a service exists
    def exists?(db : DB::Database, id : Int64) : Bool
      prefix = Memo.table_prefix

      count = db.scalar(
        "SELECT COUNT(*) FROM #{prefix}services WHERE id = ?",
        id
      ).as(Int64)

      count > 0
    end

    # Get total count of services
    def count(db : DB::Database) : Int64
      prefix = Memo.table_prefix
      db.scalar("SELECT COUNT(*) FROM #{prefix}services").as(Int64)
    end

    private def read_info(rs) : Info
      Info.new(
        id: rs.read(Int64),
        provider: rs.read(String),
        model: rs.read(String),
        version: rs.read(String?),
        dimensions: rs.read(Int32),
        max_tokens: rs.read(Int32),
        created_at: Time.unix_ms(rs.read(Int64))
      )
    end
  end
end
