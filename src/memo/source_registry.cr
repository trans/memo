# Source identity registry for flexible source IDs
#
# Maps external IDs (Int64, String, or Bytes) to internal integer IDs.
# This allows the rest of the system to use efficient integer FKs
# while supporting flexible external identifiers.
#
# Integer IDs remain sortable for chronological queries.
# String IDs support UUIDs and other text identifiers.
# Bytes IDs support raw hashes and binary UUIDs.
# External IDs are optional - memo-managed sources may have no external ID.
module Memo
  module SourceRegistry
    extend self

    # Create a source with no external ID (memo-managed)
    #
    # Returns the internal (database) ID for the new source.
    def create(db : DB::Database, source_type : String) : Int64
      db.memo_dialect.insert_returning_id(
        db,
        "INSERT INTO memo_sources (source_type, created_at) VALUES (?, ?)",
        source_type, Time.utc.to_unix_ms
      )
    end

    # Resolve external ID to internal ID, creating source record if needed
    #
    # Returns the internal (database) ID for the given source.
    def resolve(
      db : DB::Database,
      source_type : String,
      external_id : ExternalId
    ) : Int64
      dialect = db.memo_dialect

      case external_id
      when Int64
        # Try to find existing source by integer ID
        internal_id = db.query_one?(
          "SELECT id FROM memo_sources WHERE source_type = ? AND external_int = ?",
          source_type, external_id,
          as: Int64
        )
        return internal_id if internal_id

        # Create new source with integer ID
        dialect.insert_returning_id(
          db,
          "INSERT INTO memo_sources (source_type, external_int, created_at) VALUES (?, ?, ?)",
          source_type, external_id, Time.utc.to_unix_ms
        )
      when Bytes
        # Try to find existing source by blob ID
        internal_id = db.query_one?(
          "SELECT id FROM memo_sources WHERE source_type = ? AND external_blob = ?",
          source_type, external_id,
          as: Int64
        )
        return internal_id if internal_id

        # Create new source with blob ID
        dialect.insert_returning_id(
          db,
          "INSERT INTO memo_sources (source_type, external_blob, created_at) VALUES (?, ?, ?)",
          source_type, external_id, Time.utc.to_unix_ms
        )
      else # String
        ext_str = external_id.as(String)
        # Try to find existing source by text ID
        internal_id = db.query_one?(
          "SELECT id FROM memo_sources WHERE source_type = ? AND external_text = ?",
          source_type, ext_str,
          as: Int64
        )
        return internal_id if internal_id

        # Create new source with text ID
        dialect.insert_returning_id(
          db,
          "INSERT INTO memo_sources (source_type, external_text, created_at) VALUES (?, ?, ?)",
          source_type, ext_str, Time.utc.to_unix_ms
        )
      end
    end

    # Get external ID and source_type from internal ID
    #
    # Returns tuple of (source_type, external_id) or nil if not found.
    # external_id may be nil if source has no external ID (memo-managed).
    def get_external(db : DB::Database, internal_id : Int64) : {String, ExternalId?}?
      db.query_one?(
        "SELECT source_type, external_int, external_text, external_blob FROM memo_sources WHERE id = ?",
        internal_id
      ) do |rs|
        source_type = rs.read(String)
        external_int = rs.read(Int64?)
        external_text = rs.read(String?)
        external_blob = rs.read(Bytes?)
        external_id : ExternalId? = external_int || external_text || external_blob
        {source_type, external_id}
      end
    end

    # Get internal ID for an external source
    #
    # Returns nil if source doesn't exist (unlike resolve, doesn't create).
    def get_internal(
      db : DB::Database,
      source_type : String,
      external_id : ExternalId
    ) : Int64?
      case external_id
      when Int64
        db.query_one?(
          "SELECT id FROM memo_sources WHERE source_type = ? AND external_int = ?",
          source_type, external_id,
          as: Int64
        )
      when Bytes
        db.query_one?(
          "SELECT id FROM memo_sources WHERE source_type = ? AND external_blob = ?",
          source_type, external_id,
          as: Int64
        )
      else # String
        db.query_one?(
          "SELECT id FROM memo_sources WHERE source_type = ? AND external_text = ?",
          source_type, external_id.as(String),
          as: Int64
        )
      end
    end

    # Get internal ID without source_type filter
    #
    # Searches integer, text, and blob IDs. Returns first match.
    # Use when source_type is unknown or when IDs are globally unique.
    def get_internal_any_type(
      db : DB::Database,
      external_id : ExternalId
    ) : Int64?
      case external_id
      when Int64
        db.query_one?(
          "SELECT id FROM memo_sources WHERE external_int = ?",
          external_id,
          as: Int64
        )
      when Bytes
        db.query_one?(
          "SELECT id FROM memo_sources WHERE external_blob = ?",
          external_id,
          as: Int64
        )
      else # String
        db.query_one?(
          "SELECT id FROM memo_sources WHERE external_text = ?",
          external_id.as(String),
          as: Int64
        )
      end
    end

    # Delete a source record and return whether it existed
    #
    # Note: This only deletes the source registry entry.
    # Caller is responsible for cleaning up related data (chunks, texts, etc.)
    def delete(
      db : DB::Database,
      source_type : String,
      external_id : ExternalId
    ) : Bool
      result = case external_id
               when Int64
                 db.exec(
                   "DELETE FROM memo_sources WHERE source_type = ? AND external_int = ?",
                   source_type, external_id
                 )
               when Bytes
                 db.exec(
                   "DELETE FROM memo_sources WHERE source_type = ? AND external_blob = ?",
                   source_type, external_id
                 )
               else # String
                 db.exec(
                   "DELETE FROM memo_sources WHERE source_type = ? AND external_text = ?",
                   source_type, external_id.as(String)
                 )
               end

      result.rows_affected > 0
    end

    # Delete source by internal ID
    def delete_by_id(db : DB::Database, internal_id : Int64) : Bool
      result = db.exec("DELETE FROM memo_sources WHERE id = ?", internal_id)
      result.rows_affected > 0
    end

    # List all sources for a given type, ordered by external ID
    #
    # For integer IDs, returns sorted by external_int (chronological).
    # For text IDs, returns sorted by external_text (alphabetical).
    # Sources without external IDs are included with nil external_id.
    def list(
      db : DB::Database,
      source_type : String,
      limit : Int32 = 100,
      offset : Int32 = 0
    ) : Array({Int64, ExternalId?})
      results = [] of {Int64, ExternalId?}

      db.query(
        "SELECT id, external_int, external_text, external_blob FROM memo_sources
         WHERE source_type = ?
         ORDER BY COALESCE(external_int, 0), external_text
         LIMIT ? OFFSET ?",
        source_type, limit, offset
      ) do |rs|
        rs.each do
          internal_id = rs.read(Int64)
          external_int = rs.read(Int64?)
          external_text = rs.read(String?)
          external_blob = rs.read(Bytes?)
          external_id : ExternalId? = external_int || external_text || external_blob
          results << {internal_id, external_id}
        end
      end

      results
    end
  end
end
