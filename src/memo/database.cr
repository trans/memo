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
    # Creates the texts table for storing original document content.
    # Text is keyed by (source_type, source_id) - the same source identifier
    # used by the application.
    #
    # This database is persistent and survives embedding regeneration.
    # Chunk text is extracted using offset/size from the chunks table.
    #
    # Also creates FTS5 virtual table for full-text search.
    #
    # TODO: Consider whether FTS5 should match on source text or chunk text.
    #       Current implementation indexes source text, so a match means
    #       the source document contains the term. This may return chunks
    #       that don't themselves contain the search term.
    def init_text_db(db : DB::Database, schema_name : String = "text_store")
      # Main text storage table - keyed by source, not chunk hash
      db.exec(<<-SQL)
        CREATE TABLE IF NOT EXISTS #{schema_name}.texts (
          source_type TEXT NOT NULL,
          source_id INTEGER NOT NULL,
          content TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          PRIMARY KEY (source_type, source_id)
        )
      SQL

      # FTS5 virtual table for full-text search on source content
      db.exec(<<-SQL)
        CREATE VIRTUAL TABLE IF NOT EXISTS #{schema_name}.texts_fts
        USING fts5(source_type, source_id UNINDEXED, content)
      SQL
    end

    # Load memo schema into the provided database (shared mode)
    #
    # Creates tables with configured prefix: memo_embeddings, memo_chunks, memo_embed_queue
    # Use when Memo shares database with application tables.
    # Safe to call multiple times (uses IF NOT EXISTS)
    def load_schema(db : DB::Database)
      schema_dir = File.join(__DIR__, "../../db/schema")
      sql_files = Dir.glob(File.join(schema_dir, "[0-9]*.sql")).sort

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

      # Replace INSERT INTO table names
      sql = sql.gsub(/INSERT OR IGNORE INTO (\w+)/) do |match|
        table_name = $1
        "INSERT OR IGNORE INTO #{prefix}#{table_name}"
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
