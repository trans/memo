module Memo
  # Database initialization and schema management
  module Database
    extend self

    # Initialize Memo schema in provided database
    #
    # Uses the dialect attached to the db connection to generate
    # the correct DDL for the backend (SQLite or PostgreSQL).
    # Safe to call multiple times (uses IF NOT EXISTS)
    def init(db : DB::Database)
      dialect = db.memo_dialect
      dialect.schema_statements.each do |statement|
        db.exec(statement)
      end
    end

    # Create database connection and initialize schema (standalone mode)
    #
    # Accepts either a file path (SQLite) or connection string (postgres://...).
    # Sets the appropriate dialect automatically.
    def create(path : String) : DB::Database
      if path.starts_with?("postgres")
        db = DB.open(path)
        db.memo_dialect = Dialect.for(path)
      else
        db = DB.open("sqlite3:#{path}")
      end
      init(db)
      db
    end

    # Load memo schema into the provided database (embedded mode)
    # Safe to call multiple times (uses IF NOT EXISTS)
    def load_schema(db : DB::Database)
      init(db)
    end
  end
end
