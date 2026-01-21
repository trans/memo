module Memo
  # Low-level storage operations for embeddings and chunks
  module Storage
    extend self

    # Compute SHA256 hash for text content
    def compute_hash(text : String) : Bytes
      Digest::SHA256.digest(text)
    end

    # Register or get existing service by name
    #
    # Returns service_id for the named service configuration.
    # If name is nil, auto-generates from "format/model".
    def register_service(
      db : DB::Database,
      name : String?,
      format : String,
      base_url : String?,
      model : String,
      dimensions : Int32,
      max_tokens : Int32
    ) : Int64
      prefix = Memo.table_prefix

      # Auto-generate name if not provided
      service_name = name || "#{format}/#{model}"

      # Try to get existing service by name
      service_id = db.query_one?(
        "SELECT id FROM #{prefix}services WHERE name = ?",
        service_name,
        as: Int64
      )

      return service_id if service_id

      # Insert new service
      db.exec(
        "INSERT INTO #{prefix}services (name, format, base_url, model, dimensions, max_tokens, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)",
        service_name, format, base_url, model, dimensions, max_tokens, Time.utc.to_unix_ms
      )

      db.scalar("SELECT last_insert_rowid()").as(Int64)
    end

    # Get service by name
    #
    # Returns service record or nil if not found
    def get_service_by_name(
      db : DB::Database,
      name : String
    ) : {Int64, String, String?, String, Int32, Int32, Float64}?
      prefix = Memo.table_prefix

      db.query_one?(
        "SELECT id, format, base_url, model, dimensions, max_tokens, COALESCE(tokens_per_byte, 0.25)
         FROM #{prefix}services WHERE name = ?",
        name
      ) do |rs|
        {
          rs.read(Int64),   # id
          rs.read(String),  # format
          rs.read(String?), # base_url
          rs.read(String),  # model
          rs.read(Int32),   # dimensions
          rs.read(Int32),   # max_tokens
          rs.read(Float64), # tokens_per_byte
        }
      end
    end

    # Returns service record by format and model, or nil if not found
    def get_service_by_format_model(
      db : DB::Database,
      format : String,
      model : String
    ) : {Int64, String, String?, String, Int32, Int32, Float64}?
      prefix = Memo.table_prefix

      db.query_one?(
        "SELECT id, format, base_url, model, dimensions, max_tokens, COALESCE(tokens_per_byte, 0.25)
         FROM #{prefix}services WHERE format = ? AND model = ?",
        format, model
      ) do |rs|
        {
          rs.read(Int64),   # id
          rs.read(String),  # format
          rs.read(String?), # base_url
          rs.read(String),  # model
          rs.read(Int32),   # dimensions
          rs.read(Int32),   # max_tokens
          rs.read(Float64), # tokens_per_byte
        }
      end
    end

    # Update tokens_per_byte ratio for a service using exponential moving average
    #
    # Blends new observation with existing ratio: new = old * 0.9 + observed * 0.1
    def update_tokens_per_byte(
      db : DB::Database,
      service_id : Int64,
      observed_ratio : Float64
    )
      prefix = Memo.table_prefix

      # Get current ratio
      current = db.query_one?(
        "SELECT COALESCE(tokens_per_byte, 0.25) FROM #{prefix}services WHERE id = ?",
        service_id,
        as: Float64
      ) || 0.25

      # Exponential moving average: 80% old, 20% new
      updated = current * 0.8 + observed_ratio * 0.2

      db.exec(
        "UPDATE #{prefix}services SET tokens_per_byte = ? WHERE id = ?",
        updated, service_id
      )
    end

    # Store embedding in database (deduplicated by hash + service_id)
    #
    # Returns true if inserted, false if already exists for this service
    def store_embedding(
      db : DB::Database,
      hash : Bytes,
      embedding : Array(Float64),
      token_count : Int32,
      service_id : Int64
    ) : Bool
      prefix = Memo.table_prefix

      # Serialize embedding as blob (pack floats as binary)
      embedding_blob = serialize_embedding(embedding)

      # Try to insert (will skip if hash+service_id already exists due to composite PRIMARY KEY)
      result = db.exec(
        "INSERT OR IGNORE INTO #{prefix}embeddings (hash, service_id, embedding, token_count, created_at)
         VALUES (?, ?, ?, ?, ?)",
        hash, service_id, embedding_blob, token_count, Time.utc.to_unix_ms
      )

      # Return true if we actually inserted a new row
      result.rows_affected > 0
    end

    # Get embedding by hash and service_id
    #
    # Returns nil if not found
    def get_embedding(db : DB::Database, hash : Bytes, service_id : Int64) : Array(Float64)?
      prefix = Memo.table_prefix

      db.query_one?(
        "SELECT embedding FROM #{prefix}embeddings WHERE hash = ? AND service_id = ?",
        hash, service_id
      ) do |rs|
        blob = rs.read(Bytes)
        deserialize_embedding(blob)
      end
    end

    # Create chunk reference (or ignore if already exists)
    #
    # Links a hash to a source with optional relationships.
    # Uses INSERT OR IGNORE to safely handle re-indexing with different services.
    #
    # Returns chunk id if inserted, or 0 if chunk already existed (was ignored)
    def create_chunk(
      db : DB::Database,
      hash : Bytes,
      source_type : String,
      source_id : Int64,
      offset : Int32?,
      size : Int32,
      pair_id : Int64? = nil,
      parent_id : Int64? = nil
    ) : Int64
      prefix = Memo.table_prefix

      result = db.exec(
        "INSERT OR IGNORE INTO #{prefix}chunks
         (hash, source_type, source_id, pair_id, parent_id, offset, size, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        hash, source_type, source_id, pair_id, parent_id, offset, size, Time.utc.to_unix_ms
      )

      # Return 0 if insert was ignored (chunk already exists)
      return 0_i64 if result.rows_affected == 0

      db.scalar("SELECT last_insert_rowid()").as(Int64)
    end

    # Increment match_count for chunks
    def increment_match_count(db : DB::Database, chunk_ids : Array(Int64))
      return if chunk_ids.empty?

      prefix = Memo.table_prefix
      placeholders = chunk_ids.map { "?" }.join(", ")

      db.exec(
        "UPDATE #{prefix}chunks
         SET match_count = match_count + 1
         WHERE id IN (#{placeholders})",
        args: chunk_ids
      )
    end

    # Increment read_count for chunks
    def increment_read_count(db : DB::Database, chunk_ids : Array(Int64))
      return if chunk_ids.empty?

      prefix = Memo.table_prefix
      placeholders = chunk_ids.map { "?" }.join(", ")

      db.exec(
        "UPDATE #{prefix}chunks
         SET read_count = read_count + 1
         WHERE id IN (#{placeholders})",
        args: chunk_ids
      )
    end

    # Serialize embedding to binary blob (little-endian Float32 for space efficiency)
    #
    # TODO: Consider int16 normalization for embeddings to reduce storage by 50%
    #       (1536 dims: 6KB -> 3KB). Precision loss is ~0.003% for normalized vectors.
    #       Would require mapping float range [-1,1] to int16 range [-32768,32767].
    def serialize_embedding(embedding : Array(Float64)) : Bytes
      io = IO::Memory.new
      embedding.each do |value|
        io.write_bytes(value.to_f32, IO::ByteFormat::LittleEndian)
      end
      io.to_slice
    end

    # Deserialize embedding from binary blob
    def deserialize_embedding(blob : Bytes) : Array(Float64)
      io = IO::Memory.new(blob)
      embedding = [] of Float64

      # Each float32 is 4 bytes
      (blob.size // 4).times do
        embedding << io.read_bytes(Float32, IO::ByteFormat::LittleEndian).to_f64
      end

      embedding
    end
  end
end
