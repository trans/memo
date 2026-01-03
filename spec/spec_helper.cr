require "spec"
require "../src/memo"

# Helper to create a test database connection (for low-level API tests)
def with_test_db(&block : DB::Database ->)
  # Use file-based temp database to avoid connection pool isolation issues
  # In-memory databases are per-connection, so transactions can't see schema
  temp_file = File.tempname("memo_test", ".db")
  db = DB.open("sqlite3:#{temp_file}")
  Memo::Database.load_schema(db)

  begin
    yield db
  ensure
    db.close
    File.delete(temp_file) if File.exists?(temp_file)
  end
end

# Helper to create a test database path (creates temp file)
def with_test_db_path(&block : String ->)
  # Use file-based temp database
  temp_file = File.tempname("memo_test", ".db")

  begin
    yield temp_file
  ensure
    File.delete(temp_file) if File.exists?(temp_file)
  end
end

# Helper to create a test service instance
def with_test_service(&block : Memo::Service ->)
  with_test_db_path do |db_path|
    service = Memo::Service.new(
      db_path: db_path,
      provider: "mock",
      chunking_max_tokens: 50  # Mock provider has max_tokens of 100
    )

    begin
      yield service
    ensure
      service.close
    end
  end
end
