module Memo
  # Database initialization and schema management
  #
  # Memo doesn't own the database - the application provides a DB handle
  # and memo loads its schema into it. All memo tables are prefixed with
  # the configured table_prefix (default "memo_").
  module Database
    extend self

    # Load memo schema into the provided database
    #
    # Creates tables: memo_embeddings, memo_chunks, memo_embed_queue
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
