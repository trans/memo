module Memo
  # Database initialization and schema management
  #
  # Memo can operate in two modes:
  # 1. Shared database: Uses table_prefix (default "memo_") to avoid conflicts
  # 2. Standalone database: No prefix needed, tables named: services, embeddings, chunks, embed_queue
  module Database
    extend self

    # Initialize Memo schema in provided database (standalone mode)
    #
    # Loads consolidated schema without table prefixes.
    # Use when Memo has its own dedicated database file.
    # Safe to call multiple times (uses IF NOT EXISTS)
    def init(db : DB::Database)
      schema_path = File.join(__DIR__, "../../db/schema/memo_schema.sql")
      sql = File.read(schema_path)

      # Split into individual statements and execute separately
      # SQLite driver may not handle multiple statements in one exec()
      statements = sql.split(";").map(&.strip).reject(&.empty?)
      statements.each do |statement|
        # Skip comment-only statements
        next if statement.lines.all? { |line| line.strip.empty? || line.strip.starts_with?("--") }

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

    # Initialize text storage database schema
    #
    # Creates the texts table for storing document content.
    # Text is keyed by content hash (same as embeddings).
    # This database is persistent and survives embedding regeneration.
    #
    # Also creates FTS5 virtual table for full-text search.
    def init_text_db(db : DB::Database, schema_name : String = "text_store")
      # Main text storage table
      db.exec(<<-SQL)
        CREATE TABLE IF NOT EXISTS #{schema_name}.texts (
          hash BLOB PRIMARY KEY,
          content TEXT NOT NULL
        )
      SQL

      # FTS5 virtual table for full-text search
      # Uses hash as the rowid for joining back to texts table
      db.exec(<<-SQL)
        CREATE VIRTUAL TABLE IF NOT EXISTS #{schema_name}.texts_fts
        USING fts5(hash UNINDEXED, content)
      SQL
    end

    # Load memo schema into the provided database (shared mode)
    #
    # Creates tables with configured prefix: memo_embeddings, memo_chunks, memo_embed_queue
    # Use when Memo shares database with application tables.
    # Safe to call multiple times (uses IF NOT EXISTS)
    def load_schema(db : DB::Database)
      schema_dir = File.join(__DIR__, "../../db/schema")
      sql_files = Dir.glob(File.join(schema_dir, "*.sql")).sort

      sql_files.each do |file|
        execute_schema_file(db, file)
      end
    end

    # Execute a schema file with table prefix substitution
    private def execute_schema_file(db : DB::Database, path : String)
      sql = File.read(path)

      # Replace table names with prefixed versions
      # Assumes tables are created as: CREATE TABLE IF NOT EXISTS table_name
      prefix = Memo.table_prefix
      sql = sql.gsub(/CREATE TABLE IF NOT EXISTS (\w+)/) do |match|
        table_name = $1
        "CREATE TABLE IF NOT EXISTS #{prefix}#{table_name}"
      end

      # Replace index names with prefixed versions
      sql = sql.gsub(/CREATE INDEX IF NOT EXISTS (\w+) ON (\w+)/) do |match|
        index_name = $1
        table_name = $2
        "CREATE INDEX IF NOT EXISTS #{prefix}#{index_name} ON #{prefix}#{table_name}"
      end

      # Replace FOREIGN KEY references
      sql = sql.gsub(/REFERENCES (\w+)\(/) do |match|
        table_name = $1
        "REFERENCES #{prefix}#{table_name}("
      end

      # Split into individual statements and execute separately
      # SQLite driver may not handle multiple statements in one exec()
      statements = sql.split(";").map(&.strip).reject(&.empty?)
      statements.each do |statement|
        # Skip comment-only statements
        next if statement.lines.all? { |line| line.strip.empty? || line.strip.starts_with?("--") }

        db.exec(statement)
      end
    end
  end
end
