module Memo
  # Database initialization and schema management
  #
  # Memo can operate in two modes:
  # 1. Standalone: Memo has its own memo.db file, no table prefix needed
  # 2. Embedded: Tables in app's database with prefix (default "memo_")
  module Database
    extend self

    # Initialize Memo schema in provided database
    #
    # Uses the dialect attached to the db connection to generate
    # the correct DDL for the backend (SQLite or PostgreSQL).
    # Safe to call multiple times (uses IF NOT EXISTS)
    def init(db : DB::Database)
      dialect = db.memo_dialect
      prefix = db.memo_table_prefix

      statements = dialect.schema_statements(prefix)
      statements.each do |statement|
        db.exec(statement)
      end
    end

    # Create new database file and initialize schema (standalone mode)
    #
    # Creates a new SQLite database at the specified path and loads Memo schema.
    # Returns the database connection.
    def create(path : String) : DB::Database
      db = DB.open("sqlite3:#{path}")
      init(db)
      db
    end

    # Load memo schema into the provided database (embedded mode)
    #
    # Creates tables with configured prefix (e.g., memo_embeddings, memo_chunks)
    # Use when Memo shares database with application tables.
    # Safe to call multiple times (uses IF NOT EXISTS)
    def load_schema(db : DB::Database)
      init(db)
    end
  end
end
