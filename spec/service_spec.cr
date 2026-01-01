require "./spec_helper"

describe Memo::Service do
  describe "#initialize" do
    it "initializes with valid mock config" do
      with_test_service do |service|
        service.service_id.should be > 0
        service.provider.should be_a(Memo::Providers::Mock)
      end
    end

    it "validates chunking vs provider limits" do
      expect_raises(ArgumentError, /exceeds provider limit/) do
        with_test_db do |db|
          Memo::Service.new(
            db: db,
            provider: "mock",
            chunking_max_tokens: 10000, # > mock's 100 limit
            max_tokens: 100
          )
        end
      end
    end

    it "requires api_key for openai provider" do
      expect_raises(ArgumentError, /api_key required/) do
        with_test_db do |db|
          Memo::Service.new(
            db: db,
            provider: "openai"
          )
        end
      end
    end

    it "rejects unknown providers" do
      expect_raises(ArgumentError, /Unknown provider/) do
        with_test_db do |db|
          Memo::Service.new(
            db: db,
            provider: "unknown"
          )
        end
      end
    end
  end

  describe "#index" do
    it "indexes a simple document" do
      with_test_service do |service|
        count = service.index(
          source_type: "event",
          source_id: 1_i64,
          text: "The quick brown fox jumps over the lazy dog"
        )
        count.should be > 0
      end
    end

    it "returns 0 for empty text" do
      with_test_service do |service|
        count = service.index(
          source_type: "event",
          source_id: 1_i64,
          text: ""
        )
        count.should eq(0)
      end
    end

    it "stores chunks with source metadata" do
      with_test_service do |service|
        service.index(
          source_type: "event",
          source_id: 42_i64,
          text: "Test document"
        )

        # Verify chunk was stored
        result = service.db.query_one(
          "SELECT source_type, source_id FROM #{Memo.table_prefix}chunks LIMIT 1",
          as: {String, Int64}
        )
        result.should eq({"event", 42_i64})
      end
    end

    it "handles pair_id and parent_id" do
      with_test_service do |service|
        service.index(
          source_type: "event",
          source_id: 1_i64,
          text: "Test with relationships",
          pair_id: 99_i64,
          parent_id: 88_i64
        )

        # Verify relationships stored
        result = service.db.query_one(
          "SELECT pair_id, parent_id FROM #{Memo.table_prefix}chunks LIMIT 1",
          as: {Int64?, Int64?}
        )
        result.should eq({99_i64, 88_i64})
      end
    end
  end

  describe "#search" do
    it "searches and finds indexed documents" do
      with_test_service do |service|
        # Index a document
        service.index(
          source_type: "event",
          source_id: 1_i64,
          text: "The quick brown fox jumps over the lazy dog"
        )

        # Search for it (use min_score: 0.0 since mock provider uses hash-based embeddings)
        results = service.search(query: "fox jumps", limit: 5, min_score: 0.0)
        results.size.should be > 0
        results.first.source_type.should eq("event")
        results.first.source_id.should eq(1_i64)
      end
    end

    it "returns empty array when no matches" do
      with_test_service do |service|
        results = service.search(query: "nonexistent", limit: 5)
        results.should be_empty
      end
    end

    it "filters by source_type" do
      with_test_service do |service|
        # Index two different types
        service.index(source_type: "event", source_id: 1_i64, text: "Event document")
        service.index(source_type: "idea", source_id: 2_i64, text: "Idea document")

        # Search filtering by type
        results = service.search(query: "document", source_type: "event")
        results.all? { |r| r.source_type == "event" }.should be_true
      end
    end

    it "respects min_score threshold" do
      with_test_service do |service|
        service.index(source_type: "event", source_id: 1_i64, text: "Test document")

        # High min_score should return no results
        results = service.search(query: "test", min_score: 0.99)
        results.should be_empty
      end
    end
  end

  describe "#mark_as_read" do
    it "increments read_count for chunks" do
      with_test_service do |service|
        service.index(source_type: "event", source_id: 1_i64, text: "Test document")

        # Get chunk ID
        chunk_id = service.db.scalar("SELECT id FROM #{Memo.table_prefix}chunks LIMIT 1").as(Int64)

        # Mark as read
        service.mark_as_read([chunk_id])

        # Verify read_count incremented
        read_count = service.db.scalar(
          "SELECT read_count FROM #{Memo.table_prefix}chunks WHERE id = ?",
          chunk_id
        ).as(Int64)
        read_count.should eq(1)
      end
    end
  end
end
