module Memo
  # Public CRUD interface for service configurations
  #
  # Manages the services table which stores named embedding service
  # configurations. Each service represents a unique embedding
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
  #   name: "azure-prod",
  #   format: "openai",
  #   base_url: "https://mycompany.openai.azure.com/",
  #   model: "text-embedding-ada-002",
  #   dimensions: 1536,
  #   max_tokens: 8191
  # )
  #
  # # List all services
  # services = Memo::ServiceProvider.list(db)
  #
  # # Get a specific service by name
  # service = Memo::ServiceProvider.get_by_name(db, "azure-prod")
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
      getter name : String
      getter format : String
      getter base_url : String?
      getter model : String
      getter dimensions : Int32
      getter max_tokens : Int32
      getter created_at : Time

      def initialize(
        @id : Int64,
        @name : String,
        @format : String,
        @base_url : String?,
        @model : String,
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
    # If a service with the same name already exists, raises an error.
    #
    # Returns the created service info.
    def create(
      db : DB::Database,
      name : String,
      format : String,
      model : String,
      dimensions : Int32,
      max_tokens : Int32,
      base_url : String? = nil
    ) : Info
      prefix = Memo.table_prefix

      # Check if name already exists
      existing = get_by_name(db, name)
      if existing
        raise ArgumentError.new("Service '#{name}' already exists")
      end

      # Insert new service
      now = Time.utc
      db.exec(
        "INSERT INTO #{prefix}services (name, format, base_url, model, dimensions, max_tokens, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)",
        name, format, base_url, model, dimensions, max_tokens, now.to_unix_ms
      )

      id = db.scalar("SELECT last_insert_rowid()").as(Int64)

      Info.new(
        id: id,
        name: name,
        format: format,
        base_url: base_url,
        model: model,
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
        "SELECT id, name, format, base_url, model, dimensions, max_tokens, created_at
         FROM #{prefix}services WHERE id = ?",
        id
      ) do |rs|
        read_info(rs)
      end
    end

    # Get a service by name
    #
    # Returns nil if not found.
    def get_by_name(db : DB::Database, name : String) : Info?
      prefix = Memo.table_prefix

      db.query_one?(
        "SELECT id, name, format, base_url, model, dimensions, max_tokens, created_at
         FROM #{prefix}services WHERE name = ?",
        name
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
        "SELECT id, name, format, base_url, model, dimensions, max_tokens, created_at
         FROM #{prefix}services
         ORDER BY created_at DESC"
      ) do |rs|
        rs.each do
          services << read_info(rs)
        end
      end

      services
    end

    # List services by format
    #
    # Returns array of service info for the specified API format.
    def list_by_format(db : DB::Database, format : String) : Array(Info)
      prefix = Memo.table_prefix
      services = [] of Info

      db.query(
        "SELECT id, name, format, base_url, model, dimensions, max_tokens, created_at
         FROM #{prefix}services
         WHERE format = ?
         ORDER BY created_at DESC",
        format
      ) do |rs|
        rs.each do
          services << read_info(rs)
        end
      end

      services
    end

    # Update a service configuration
    #
    # Can update base_url and max_tokens. Other fields define the service identity.
    # Returns the updated service info, or nil if not found.
    def update(
      db : DB::Database,
      id : Int64,
      base_url : String? = nil,
      max_tokens : Int32? = nil
    ) : Info?
      prefix = Memo.table_prefix

      # Build update query dynamically
      updates = [] of String
      params = [] of DB::Any

      if base_url
        updates << "base_url = ?"
        params << base_url
      end

      if max_tokens
        updates << "max_tokens = ?"
        params << max_tokens
      end

      return get(db, id) if updates.empty?

      params << id

      result = db.exec(
        "UPDATE #{prefix}services SET #{updates.join(", ")} WHERE id = ?",
        args: params
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
        name: rs.read(String),
        format: rs.read(String),
        base_url: rs.read(String?),
        model: rs.read(String),
        dimensions: rs.read(Int32),
        max_tokens: rs.read(Int32),
        created_at: Time.unix_ms(rs.read(Int64))
      )
    end
  end
end
