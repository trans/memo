module Memo
  module Dialect
    class SQLite < Base
      def insert_returning_id(db : DB::Database, sql : String, *args) : Int64
        db.exec(sql, *args)
        db.scalar("SELECT last_insert_rowid()").as(Int64)
      end

      def insert_or_ignore_sql(table : String, columns : String, placeholders : String) : String
        "INSERT OR IGNORE INTO #{table} (#{columns}) VALUES (#{placeholders})"
      end

      def upsert_sql(
        table : String,
        columns : String,
        placeholders : String,
        conflict_columns : String,
        update_columns : Array(String)
      ) : String
        "INSERT OR REPLACE INTO #{table} (#{columns}) VALUES (#{placeholders})"
      end

      def embedding_rowid_column : String
        "rowid"
      end

      def schema_statements(prefix : String) : Array(String)
        schema_path = File.join(__DIR__, "../../../db/schema/memo_schema.sql")
        sql = File.read(schema_path)

        sql = apply_prefix(sql, prefix)

        # Split into individual statements
        statements = sql.split(";").map(&.strip).reject(&.empty?)
        statements.reject do |statement|
          statement.lines.all? { |line| line.strip.empty? || line.strip.starts_with?("--") }
        end
      end

      def db_file_path(db : DB::Database) : String?
        db.query_one?(
          "SELECT file FROM pragma_database_list WHERE name = 'main'",
          as: String
        )
      end

      def fts_create_statements(prefix : String) : Array(String)
        [
          "CREATE VIRTUAL TABLE IF NOT EXISTS #{prefix}texts_fts USING fts5(source_id UNINDEXED, content)",
        ]
      end

      def fts_upsert(db : DB::Database, prefix : String, source_id : Int64, content : String)
        # FTS5 doesn't support INSERT OR REPLACE, so delete-then-insert
        db.exec("DELETE FROM #{prefix}texts_fts WHERE source_id = ?", source_id)
        db.exec("INSERT INTO #{prefix}texts_fts (source_id, content) VALUES (?, ?)", source_id, content)
      end

      def fts_delete(db : DB::Database, prefix : String, source_id : Int64)
        db.exec("DELETE FROM #{prefix}texts_fts WHERE source_id = ?", source_id)
      end

      def fts_join_sql(prefix : String) : String
        "JOIN #{prefix}texts_fts ON c.source_id = #{prefix}texts_fts.source_id"
      end

      def fts_where_sql(prefix : String) : String
        "#{prefix}texts_fts MATCH ?"
      end

      # Apply table prefix to raw schema SQL
      private def apply_prefix(sql : String, prefix : String) : String
        sql = sql.gsub(/CREATE TABLE IF NOT EXISTS (\w+)/) do |match|
          "CREATE TABLE IF NOT EXISTS #{prefix}#{$1}"
        end

        sql = sql.gsub(/CREATE VIRTUAL TABLE IF NOT EXISTS (\w+)/) do |match|
          "CREATE VIRTUAL TABLE IF NOT EXISTS #{prefix}#{$1}"
        end

        sql = sql.gsub(/CREATE INDEX IF NOT EXISTS (\w+) ON (\w+)/) do |match|
          "CREATE INDEX IF NOT EXISTS #{prefix}#{$1} ON #{prefix}#{$2}"
        end

        sql = sql.gsub(/REFERENCES (\w+)\(/) do |match|
          "REFERENCES #{prefix}#{$1}("
        end

        sql = sql.gsub(/INSERT OR IGNORE INTO (\w+)/) do |match|
          "INSERT OR IGNORE INTO #{prefix}#{$1}"
        end

        sql
      end
    end
  end
end
