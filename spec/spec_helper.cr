require "spec"
require "../src/memo"

# Helper to create a test database connection (for low-level API tests)
def with_test_db(&block : DB::Database ->)
  # Reset table prefix to default (Service tests may have changed it)
  Memo.table_prefix = "memo_"

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

# Helper to create a test data directory
def with_test_data_dir(&block : String ->)
  # Create temp directory for test databases
  temp_dir = File.tempname("memo_test", "")
  Dir.mkdir_p(temp_dir)

  begin
    yield temp_dir
  ensure
    # Clean up all files in directory
    if Dir.exists?(temp_dir)
      Dir.each_child(temp_dir) do |file|
        File.delete(File.join(temp_dir, file))
      end
      Dir.delete(temp_dir)
    end
  end
end

# Helper to create a test service instance
def with_test_service(&block : Memo::Service ->)
  with_test_data_dir do |data_dir|
    service = Memo::Service.new(
      data_dir: data_dir,
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
