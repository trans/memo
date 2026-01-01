module Memo
  # Low-level storage operations for embeddings and chunks
  module Storage
    extend self

    # Compute SHA256 hash for text content
    def compute_hash(text : String) : Bytes
      Digest::SHA256.digest(text)
    end

    # Register or get existing service
    #
    # Returns service_id for the provider/model combination
    def register_service(
      db : DB::Database,
      provider : String,
      model : String,
      version : String?,
      dimensions : Int32,
      max_tokens : Int32
    ) : Int64
      prefix = Memo.table_prefix

      # Try to get existing service
      service_id = db.query_one?(
        "SELECT id FROM #{prefix}services WHERE provider = ? AND model = ? AND version IS ? AND dimensions = ?",
        provider, model, version, dimensions,
        as: Int64
      )

      return service_id if service_id

      # Insert new service
      db.exec(
        "INSERT INTO #{prefix}services (provider, model, version, dimensions, max_tokens, created_at)
         VALUES (?, ?, ?, ?, ?, ?)",
        provider, model, version, dimensions, max_tokens, Time.utc.to_unix_ms
      )

      db.scalar("SELECT last_insert_rowid()").as(Int64)
    end

    # Store embedding in database (deduplicated by hash)
    #
    # Returns true if inserted, false if already exists
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

      # Try to insert (will fail if hash already exists due to PRIMARY KEY)
      db.exec(
        "INSERT OR IGNORE INTO #{prefix}embeddings (hash, embedding, token_count, service_id, created_at)
         VALUES (?, ?, ?, ?, ?)",
        hash, embedding_blob, token_count, service_id, Time.utc.to_unix_ms
      )

      # Check if we actually inserted
      exists = db.scalar(
        "SELECT COUNT(*) FROM #{prefix}embeddings WHERE hash = ?",
        hash
      ).as(Int64)

      exists > 0
    end

    # Get embedding by hash
    #
    # Returns nil if not found
    def get_embedding(db : DB::Database, hash : Bytes) : Array(Float64)?
      prefix = Memo.table_prefix

      db.query_one?(
        "SELECT embedding FROM #{prefix}embeddings WHERE hash = ?",
        hash
      ) do |rs|
        blob = rs.read(Bytes)
        deserialize_embedding(blob)
      end
    end

    # Create chunk reference
    #
    # Links a hash to a source with optional relationships
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

      db.exec(
        "INSERT INTO #{prefix}chunks
         (hash, source_type, source_id, pair_id, parent_id, offset, size, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        hash, source_type, source_id, pair_id, parent_id, offset, size, Time.utc.to_unix_ms
      )

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
