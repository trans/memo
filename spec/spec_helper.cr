require "spec"
require "../src/memo"

# Helper to create a test database in memory
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

# Helper to create a test service instance
def with_test_service(&block : Memo::Service ->)
  with_test_db do |db|
    service = Memo::Service.new(
      db: db,
      provider: "mock",
      chunking_max_tokens: 50  # Mock provider has max_tokens of 100
    )
    yield service
  end
end
