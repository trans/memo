# Source identity registry for flexible source IDs
#
# Maps external IDs (Int64 or String) to internal integer IDs.
# This allows the rest of the system to use efficient integer FKs
# while supporting flexible external identifiers.
#
# Integer IDs remain sortable for chronological queries.
# String IDs support UUIDs and other text identifiers.
module Memo
  module SourceRegistry
    extend self

    # Resolve external ID to internal ID, creating source record if needed
    #
    # Returns the internal (database) ID for the given source.
    def resolve(
      db : DB::Database,
      source_type : String,
      external_id : ExternalId
    ) : Int64
      prefix = Memo.table_prefix

      case external_id
      when Int64
        # Try to find existing source by integer ID
        internal_id = db.query_one?(
          "SELECT id FROM #{prefix}sources WHERE source_type = ? AND external_int = ?",
          source_type, external_id,
          as: Int64
        )
        return internal_id if internal_id

        # Create new source with integer ID
        db.exec(
          "INSERT INTO #{prefix}sources (source_type, external_int, created_at) VALUES (?, ?, ?)",
          source_type, external_id, Time.utc.to_unix_ms
        )
        db.scalar("SELECT last_insert_rowid()").as(Int64)

      else # String
        ext_str = external_id.as(String)
        # Try to find existing source by text ID
        internal_id = db.query_one?(
          "SELECT id FROM #{prefix}sources WHERE source_type = ? AND external_text = ?",
          source_type, ext_str,
          as: Int64
        )
        return internal_id if internal_id

        # Create new source with text ID
        db.exec(
          "INSERT INTO #{prefix}sources (source_type, external_text, created_at) VALUES (?, ?, ?)",
          source_type, ext_str, Time.utc.to_unix_ms
        )
        db.scalar("SELECT last_insert_rowid()").as(Int64)
      end
    end

    # Get external ID and source_type from internal ID
    #
    # Returns tuple of (source_type, external_id) or nil if not found.
    def get_external(db : DB::Database, internal_id : Int64) : {String, ExternalId}?
      prefix = Memo.table_prefix

      db.query_one?(
        "SELECT source_type, external_int, external_text FROM #{prefix}sources WHERE id = ?",
        internal_id
      ) do |rs|
        source_type = rs.read(String)
        external_int = rs.read(Int64?)
        external_text = rs.read(String?)

        external_id : ExternalId = external_int || external_text.not_nil!
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
      prefix = Memo.table_prefix

      case external_id
      when Int64
        db.query_one?(
          "SELECT id FROM #{prefix}sources WHERE source_type = ? AND external_int = ?",
          source_type, external_id,
          as: Int64
        )
      else # String
        db.query_one?(
          "SELECT id FROM #{prefix}sources WHERE source_type = ? AND external_text = ?",
          source_type, external_id.as(String),
          as: Int64
        )
      end
    end

    # Get internal ID without source_type filter
    #
    # Searches both integer and text IDs. Returns first match.
    # Use when source_type is unknown or when IDs are globally unique.
    def get_internal_any_type(
      db : DB::Database,
      external_id : ExternalId
    ) : Int64?
      prefix = Memo.table_prefix

      case external_id
      when Int64
        db.query_one?(
          "SELECT id FROM #{prefix}sources WHERE external_int = ?",
          external_id,
          as: Int64
        )
      else # String
        db.query_one?(
          "SELECT id FROM #{prefix}sources WHERE external_text = ?",
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
      prefix = Memo.table_prefix

      result = case external_id
               when Int64
                 db.exec(
                   "DELETE FROM #{prefix}sources WHERE source_type = ? AND external_int = ?",
                   source_type, external_id
                 )
               else # String
                 db.exec(
                   "DELETE FROM #{prefix}sources WHERE source_type = ? AND external_text = ?",
                   source_type, external_id.as(String)
                 )
               end

      result.rows_affected > 0
    end

    # Delete source by internal ID
    def delete_by_id(db : DB::Database, internal_id : Int64) : Bool
      prefix = Memo.table_prefix
      result = db.exec("DELETE FROM #{prefix}sources WHERE id = ?", internal_id)
      result.rows_affected > 0
    end

    # List all sources for a given type, ordered by external ID
    #
    # For integer IDs, returns sorted by external_int (chronological).
    # For text IDs, returns sorted by external_text (alphabetical).
    def list(
      db : DB::Database,
      source_type : String,
      limit : Int32 = 100,
      offset : Int32 = 0
    ) : Array({Int64, ExternalId})
      prefix = Memo.table_prefix
      results = [] of {Int64, ExternalId}

      db.query(
        "SELECT id, external_int, external_text FROM #{prefix}sources
         WHERE source_type = ?
         ORDER BY COALESCE(external_int, 0), external_text
         LIMIT ? OFFSET ?",
        source_type, limit, offset
      ) do |rs|
        rs.each do
          internal_id = rs.read(Int64)
          external_int = rs.read(Int64?)
          external_text = rs.read(String?)
          external_id : ExternalId = external_int || external_text.not_nil!
          results << {internal_id, external_id}
        end
      end

      results
    end
  end
end
