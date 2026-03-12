module Memo
  # Low-level storage operations for embeddings and chunks
  module Storage
    extend self

    # Compute SHA256 hash for text content
    def compute_hash(text : String) : Bytes
      Digest::SHA256.digest(text)
    end

    # Register or get existing service by name
    def register_service(
      db : DB::Database,
      name : String?,
      format : String,
      base_url : String?,
      model : String,
      dimensions : Int32,
      max_tokens : Int32
    ) : Int64
      service_name = name || "#{format}/#{model}"

      service_id = db.query_one?(
        "SELECT id FROM memo_services WHERE name = ?",
        service_name,
        as: Int64
      )

      return service_id if service_id

      db.memo_dialect.insert_returning_id(
        db,
        "INSERT INTO memo_services (name, format, base_url, model, dimensions, max_tokens, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)",
        service_name, format, base_url, model, dimensions, max_tokens, Time.utc.to_unix_ms
      )
    end

    # Get service by name
    def get_service_by_name(
      db : DB::Database,
      name : String
    ) : {Int64, String, String?, String, Int32, Int32, Float64}?
      db.query_one?(
        "SELECT id, format, base_url, model, dimensions, max_tokens, COALESCE(tokens_per_byte, 0.25)
         FROM memo_services WHERE name = ?",
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
      db.query_one?(
        "SELECT id, format, base_url, model, dimensions, max_tokens, COALESCE(tokens_per_byte, 0.25)
         FROM memo_services WHERE format = ? AND model = ?",
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

    # Update tokens_per_byte ratio using exponential moving average
    def update_tokens_per_byte(
      db : DB::Database,
      service_id : Int64,
      observed_ratio : Float64
    )
      current = db.query_one?(
        "SELECT COALESCE(tokens_per_byte, 0.25) FROM memo_services WHERE id = ?",
        service_id,
        as: Float64
      ) || 0.25

      updated = current * 0.8 + observed_ratio * 0.2

      db.exec(
        "UPDATE memo_services SET tokens_per_byte = ? WHERE id = ?",
        updated, service_id
      )
    end

    # Register embedding hash in database (deduplicated by hash + service_id)
    #
    # Returns {inserted, rowid} where inserted is true if new, rowid is the USearch key.
    def store_embedding(
      db : DB::Database,
      hash : Bytes,
      token_count : Int32,
      service_id : Int64
    ) : {Bool, Int64}
      dialect = db.memo_dialect
      sql = dialect.insert_or_ignore_sql(
        "memo_embeddings",
        "hash, service_id, token_count, created_at",
        "?, ?, ?, ?"
      )
      result = db.exec(sql, hash, service_id, token_count, Time.utc.to_unix_ms)

      inserted = result.rows_affected > 0

      rid_col = dialect.embedding_rowid_column
      rowid = db.query_one(
        "SELECT #{rid_col} FROM memo_embeddings WHERE hash = ? AND service_id = ?",
        hash, service_id,
        as: Int64
      )

      {inserted, rowid}
    end

    # Get the rowid of an embedding by hash and service_id.
    def get_rowid(db : DB::Database, hash : Bytes, service_id : Int64) : Int64?
      rid_col = db.memo_dialect.embedding_rowid_column
      db.query_one?(
        "SELECT #{rid_col} FROM memo_embeddings WHERE hash = ? AND service_id = ?",
        hash, service_id,
        as: Int64
      )
    end

    # Create chunk reference (or ignore if already exists)
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
      dialect = db.memo_dialect
      sql = dialect.insert_or_ignore_sql(
        "memo_chunks",
        "hash, source_id, source_type, pair_id, parent_id, offset, size, created_at",
        "?, ?, ?, ?, ?, ?, ?, ?"
      )
      result = db.exec(sql, hash, source_id, source_type, pair_id, parent_id, offset, size, Time.utc.to_unix_ms)

      return 0_i64 if result.rows_affected == 0

      db.query_one(
        "SELECT id FROM memo_chunks WHERE source_id = ? AND offset IS ?",
        source_id, offset,
        as: Int64
      )
    end

    # Increment match_count for chunks
    def increment_match_count(db : DB::Database, chunk_ids : Array(Int64))
      return if chunk_ids.empty?
      placeholders = chunk_ids.map { "?" }.join(", ")
      db.exec(
        "UPDATE memo_chunks SET match_count = match_count + 1 WHERE id IN (#{placeholders})",
        args: chunk_ids
      )
    end

    # Increment read_count for chunks
    def increment_read_count(db : DB::Database, chunk_ids : Array(Int64))
      return if chunk_ids.empty?
      placeholders = chunk_ids.map { "?" }.join(", ")
      db.exec(
        "UPDATE memo_chunks SET read_count = read_count + 1 WHERE id IN (#{placeholders})",
        args: chunk_ids
      )
    end

    # Serialize embedding to binary blob (Int16 for 50% storage reduction)
    def serialize_embedding(embedding : Array(Float64)) : Bytes
      io = IO::Memory.new
      embedding.each do |value|
        int_val = (value.clamp(-1.0, 1.0) * 32767).round.to_i16
        io.write_bytes(int_val, IO::ByteFormat::LittleEndian)
      end
      io.to_slice
    end

    # Deserialize embedding from binary blob
    def deserialize_embedding(blob : Bytes) : Array(Float64)
      io = IO::Memory.new(blob)
      embedding = [] of Float64
      (blob.size // 2).times do
        int_val = io.read_bytes(Int16, IO::ByteFormat::LittleEndian)
        embedding << int_val.to_f64 / 32767.0
      end
      embedding
    end
  end
end
