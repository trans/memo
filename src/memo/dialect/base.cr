module Memo
  module Dialect
    # Abstract interface for SQL dialect differences between SQLite and PostgreSQL.
    #
    # Most SQL in Memo is cross-database compatible. This module only abstracts
    # the patterns that differ:
    #
    # - Insert-and-return-ID (last_insert_rowid vs RETURNING)
    # - Conflict handling (INSERT OR IGNORE, INSERT OR REPLACE)
    # - Implicit rowid (SQLite) vs explicit column (PostgreSQL)
    # - FTS5 (SQLite) vs tsvector/GIN (PostgreSQL)
    # - Schema DDL (AUTOINCREMENT, BLOB, REAL types)
    # - DB path discovery (pragma vs connection string)
    abstract class Base
      # Execute an INSERT and return the generated ID.
      #
      # SQLite: executes sql then SELECT last_insert_rowid()
      # PostgreSQL: appends RETURNING id to sql
      abstract def insert_returning_id(db : DB::Database, sql : String, *args) : Int64

      # Build INSERT OR IGNORE SQL.
      #
      # SQLite: INSERT OR IGNORE INTO table (cols) VALUES (?)
      # PostgreSQL: INSERT INTO table (cols) VALUES (?) ON CONFLICT DO NOTHING
      abstract def insert_or_ignore_sql(table : String, columns : String, placeholders : String) : String

      # Build upsert SQL (INSERT OR REPLACE equivalent).
      #
      # SQLite: INSERT OR REPLACE INTO table (cols) VALUES (?)
      # PostgreSQL: INSERT INTO table (cols) VALUES (?) ON CONFLICT (conflict_cols) DO UPDATE SET ...
      abstract def upsert_sql(
        table : String,
        columns : String,
        placeholders : String,
        conflict_columns : String,
        update_columns : Array(String)
      ) : String

      # The column name for embedding row identity used as USearch key.
      #
      # SQLite: "rowid" (implicit)
      # PostgreSQL: explicit column name (e.g., "eid")
      abstract def embedding_rowid_column : String

      # Get schema DDL statements for the given table prefix.
      #
      # Returns an array of SQL statements to execute in order.
      abstract def schema_statements(prefix : String) : Array(String)

      # Get the database file path from a connection, if applicable.
      #
      # SQLite: reads pragma_database_list
      # PostgreSQL: returns nil (no local file)
      abstract def db_file_path(db : DB::Database) : String?

      # Build FTS index creation SQL.
      #
      # SQLite: CREATE VIRTUAL TABLE ... USING fts5(...)
      # PostgreSQL: ALTER TABLE ... ADD COLUMN content_tsv tsvector; CREATE INDEX ...
      abstract def fts_create_statements(prefix : String) : Array(String)

      # Insert or update FTS index for a source.
      abstract def fts_upsert(db : DB::Database, prefix : String, source_id : Int64, content : String)

      # Delete FTS index entry for a source.
      abstract def fts_delete(db : DB::Database, prefix : String, source_id : Int64)

      # Build FTS JOIN clause for search queries.
      #
      # Returns empty string if no join needed (e.g., if FTS is on the texts table itself).
      abstract def fts_join_sql(prefix : String) : String

      # Build FTS WHERE clause for match queries.
      #
      # The placeholder `?` should accept the match query string.
      abstract def fts_where_sql(prefix : String) : String
    end
  end
end
