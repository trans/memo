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
    # Loads consolidated schema with table prefix applied.
    # Safe to call multiple times (uses IF NOT EXISTS)
    def init(db : DB::Database)
      schema_path = File.join(__DIR__, "../../db/schema/memo_schema.sql")
      sql = File.read(schema_path)
      prefix = Memo.table_prefix

      # Replace table names with prefixed versions
      sql = sql.gsub(/CREATE TABLE IF NOT EXISTS (\w+)/) do |match|
        table_name = $1
        "CREATE TABLE IF NOT EXISTS #{prefix}#{table_name}"
      end

      # Replace FTS5 virtual table names
      sql = sql.gsub(/CREATE VIRTUAL TABLE IF NOT EXISTS (\w+)/) do |match|
        table_name = $1
        "CREATE VIRTUAL TABLE IF NOT EXISTS #{prefix}#{table_name}"
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
      schema_dir = File.join(__DIR__, "../../db/schema")
      sql_files = Dir.glob(File.join(schema_dir, "[0-9]*.sql")).sort

      sql_files.each do |file|
        execute_schema_file(db, file)
      end
    end

    # Execute a schema file with table prefix substitution
    private def execute_schema_file(db : DB::Database, path : String)
      sql = File.read(path)
      prefix = Memo.table_prefix

      # Replace table names with prefixed versions
      sql = sql.gsub(/CREATE TABLE IF NOT EXISTS (\w+)/) do |match|
        table_name = $1
        "CREATE TABLE IF NOT EXISTS #{prefix}#{table_name}"
      end

      # Replace FTS5 virtual table names
      sql = sql.gsub(/CREATE VIRTUAL TABLE IF NOT EXISTS (\w+)/) do |match|
        table_name = $1
        "CREATE VIRTUAL TABLE IF NOT EXISTS #{prefix}#{table_name}"
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
