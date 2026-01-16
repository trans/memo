require "./spec_helper"

describe Memo::Service do
  describe "#initialize" do
    it "initializes with valid mock config" do
      with_test_service do |service|
        service.service_id.should be > 0
        service.provider.should be_a(Memo::Providers::Mock)
      end
    end

    it "creates projection vectors on initialization" do
      with_test_service do |service|
        service.projection_vectors.size.should eq(Memo::Projection::K)
        service.projection_vectors.each do |vec|
          vec.size.should eq(service.dimensions)
        end
      end
    end

    it "retrieves existing projection vectors on re-initialization" do
      with_test_data_dir do |data_dir|
        # First initialization creates vectors
        service1 = Memo::Service.new(
          data_dir: data_dir,
          provider: "mock",
          chunking_max_tokens: 50
        )
        original_vectors = service1.projection_vectors.clone
        service_id = service1.service_id
        service1.close

        # Re-open same database - should get same vectors
        service2 = Memo::Service.new(
          data_dir: data_dir,
          provider: "mock",
          chunking_max_tokens: 50
        )

        service2.service_id.should eq(service_id)
        service2.projection_vectors.size.should eq(original_vectors.size)

        # Vectors should match (with Float32 precision tolerance)
        original_vectors.each_with_index do |vec, i|
          vec.each_with_index do |val, j|
            (service2.projection_vectors[i][j] - val).abs.should be < 0.001
          end
        end

        service2.close
      end
    end

    it "validates chunking vs provider limits" do
      expect_raises(ArgumentError, /exceeds provider limit/) do
        with_test_data_dir do |data_dir|
          service = Memo::Service.new(
            data_dir: data_dir,
            provider: "mock",
            chunking_max_tokens: 10000, # > mock's 100 limit
            max_tokens: 100
          )
          service.close
        end
      end
    end

    it "requires api_key for openai provider" do
      expect_raises(ArgumentError, /api_key required/) do
        with_test_data_dir do |data_dir|
          service = Memo::Service.new(
            data_dir: data_dir,
            provider: "openai"
          )
          service.close
        end
      end
    end

    it "rejects unknown providers" do
      expect_raises(ArgumentError, /Unknown provider/) do
        with_test_data_dir do |data_dir|
          service = Memo::Service.new(
            data_dir: data_dir,
            provider: "unknown"
          )
          service.close
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

    it "stores projections when indexing" do
      with_test_service do |service|
        service.index(
          source_type: "event",
          source_id: 1_i64,
          text: "Test document for projection"
        )

        # Verify projections were stored
        hash = service.db.query_one(
          "SELECT hash FROM #{Memo.table_prefix}embeddings LIMIT 1",
          as: Bytes
        )

        projections = Memo::Projection.get_projections(service.db, hash)
        projections.should_not be_nil
        projections.not_nil!.size.should eq(Memo::Projection::K)
      end
    end

    it "indexes using Document struct" do
      with_test_service do |service|
        doc = Memo::Document.new(
          source_type: "event",
          source_id: 1_i64,
          text: "Document struct test"
        )

        count = service.index(doc)
        count.should be > 0

        stats = service.stats
        stats.sources.should eq(1)
      end
    end
  end

  describe "#index_batch" do
    it "indexes multiple documents in one call" do
      with_test_service do |service|
        docs = [
          Memo::Document.new(source_type: "event", source_id: 1_i64, text: "First document"),
          Memo::Document.new(source_type: "event", source_id: 2_i64, text: "Second document"),
          Memo::Document.new(source_type: "idea", source_id: 3_i64, text: "Third document"),
        ]

        count = service.index_batch(docs)
        count.should eq(3)

        stats = service.stats
        stats.sources.should eq(3)
        stats.chunks.should eq(3)
      end
    end

    it "returns 0 for empty array" do
      with_test_service do |service|
        count = service.index_batch([] of Memo::Document)
        count.should eq(0)
      end
    end

    it "skips documents with empty text" do
      with_test_service do |service|
        docs = [
          Memo::Document.new(source_type: "event", source_id: 1_i64, text: "Valid document"),
          Memo::Document.new(source_type: "event", source_id: 2_i64, text: ""),
          Memo::Document.new(source_type: "event", source_id: 3_i64, text: "Another valid"),
        ]

        count = service.index_batch(docs)
        count.should eq(2)

        stats = service.stats
        stats.sources.should eq(2)
      end
    end

    it "handles Document with pair_id and parent_id" do
      with_test_service do |service|
        docs = [
          Memo::Document.new(
            source_type: "event",
            source_id: 1_i64,
            text: "Document with relationships",
            pair_id: 99_i64,
            parent_id: 88_i64
          ),
        ]

        service.index_batch(docs)

        result = service.db.query_one(
          "SELECT pair_id, parent_id FROM #{Memo.table_prefix}chunks LIMIT 1",
          as: {Int64?, Int64?}
        )
        result.should eq({99_i64, 88_i64})
      end
    end

    it "deduplicates shared content across documents" do
      with_test_service do |service|
        docs = [
          Memo::Document.new(source_type: "event", source_id: 1_i64, text: "Shared text"),
          Memo::Document.new(source_type: "event", source_id: 2_i64, text: "Shared text"),
        ]

        count = service.index_batch(docs)
        count.should eq(2)

        stats = service.stats
        stats.embeddings.should eq(1)  # Deduplicated
        stats.chunks.should eq(2)      # Two chunks
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

  describe "#stats" do
    it "returns zero counts for empty database" do
      with_test_service do |service|
        stats = service.stats
        stats.embeddings.should eq(0)
        stats.chunks.should eq(0)
        stats.sources.should eq(0)
      end
    end

    it "counts indexed content correctly" do
      with_test_service do |service|
        # Index 3 documents
        service.index(source_type: "event", source_id: 1_i64, text: "First document")
        service.index(source_type: "event", source_id: 2_i64, text: "Second document")
        service.index(source_type: "idea", source_id: 3_i64, text: "Third document")

        stats = service.stats
        stats.embeddings.should eq(3)
        stats.chunks.should eq(3)
        stats.sources.should eq(3)
      end
    end

    it "counts unique sources when same text is indexed multiple times" do
      with_test_service do |service|
        # Index same text for different sources (deduplication)
        service.index(source_type: "event", source_id: 1_i64, text: "Same text")
        service.index(source_type: "event", source_id: 2_i64, text: "Same text")

        stats = service.stats
        stats.embeddings.should eq(1)  # Deduplicated
        stats.chunks.should eq(2)      # Two chunks
        stats.sources.should eq(2)     # Two sources
      end
    end
  end

  describe "#delete" do
    it "deletes chunks for a source" do
      with_test_service do |service|
        service.index(source_type: "event", source_id: 1_i64, text: "Document one")
        service.index(source_type: "event", source_id: 2_i64, text: "Document two")

        stats_before = service.stats
        stats_before.sources.should eq(2)

        # Delete source 1
        deleted = service.delete(source_id: 1_i64)
        deleted.should eq(1)

        stats_after = service.stats
        stats_after.sources.should eq(1)
        stats_after.chunks.should eq(1)
      end
    end

    it "cleans up orphaned embeddings" do
      with_test_service do |service|
        service.index(source_type: "event", source_id: 1_i64, text: "Unique document")

        stats_before = service.stats
        stats_before.embeddings.should eq(1)

        # Delete the only source referencing this embedding
        service.delete(source_id: 1_i64)

        stats_after = service.stats
        stats_after.embeddings.should eq(0)
      end
    end

    it "preserves shared embeddings" do
      with_test_service do |service|
        # Index same text for two sources
        service.index(source_type: "event", source_id: 1_i64, text: "Shared text")
        service.index(source_type: "event", source_id: 2_i64, text: "Shared text")

        stats_before = service.stats
        stats_before.embeddings.should eq(1)  # Deduplicated
        stats_before.chunks.should eq(2)

        # Delete one source
        service.delete(source_id: 1_i64)

        stats_after = service.stats
        stats_after.embeddings.should eq(1)  # Still referenced by source 2
        stats_after.chunks.should eq(1)
      end
    end

    it "returns 0 when source doesn't exist" do
      with_test_service do |service|
        deleted = service.delete(source_id: 999_i64)
        deleted.should eq(0)
      end
    end
  end
end
