require "./spec_helper"

describe Memo::Search do
  describe ".semantic" do
    it "returns empty results when no embeddings exist" do
      with_test_db do |db|
        service_id = Memo::Storage.register_service(
          db: db,
          provider: "test",
          model: "test-model",
          version: nil,
          dimensions: 8,
          max_tokens: 1000
        )

        query_embedding = Array.new(8) { |i| i.to_f64 }

        results = Memo::Search.semantic(
          db: db,
          embedding: query_embedding,
          service_id: service_id,
          limit: 10
        )

        results.should be_empty
      end
    end

    it "returns matching results ranked by similarity" do
      with_test_db do |db|
        service_id = Memo::Storage.register_service(
          db: db,
          provider: "test",
          model: "test-model",
          version: nil,
          dimensions: 8,
          max_tokens: 1000
        )

        # Store three embeddings
        texts = ["first", "second", "third"]
        embeddings = [
          [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],  # Similar to query
          [0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],  # Less similar
          [0.9, 0.1, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],  # Very similar to query
        ]

        texts.each_with_index do |text, i|
          hash = Memo::Storage.compute_hash(text)
          Memo::Storage.store_embedding(db, hash, embeddings[i], 10, service_id)
          Memo::Storage.create_chunk(db, hash, "document", i.to_i64, 0, 100)
        end

        # Query with embedding similar to first and third
        query_embedding = [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]

        results = Memo::Search.semantic(
          db: db,
          embedding: query_embedding,
          service_id: service_id,
          limit: 10,
          min_score: 0.5
        )

        results.size.should be >= 2
        # First result should have highest score
        results[0].score.should be >= results[1].score if results.size > 1
      end
    end

    it "filters by source_type" do
      with_test_db do |db|
        service_id = Memo::Storage.register_service(
          db: db,
          provider: "test",
          model: "test-model",
          version: nil,
          dimensions: 8,
          max_tokens: 1000
        )

        embedding = Array.new(8) { |i| i.to_f64 }

        # Store embeddings with different source types
        hash1 = Memo::Storage.compute_hash("text1")
        Memo::Storage.store_embedding(db, hash1, embedding, 10, service_id)
        Memo::Storage.create_chunk(db, hash1, "document", 1_i64, 0, 100)

        hash2 = Memo::Storage.compute_hash("text2")
        Memo::Storage.store_embedding(db, hash2, embedding, 10, service_id)
        Memo::Storage.create_chunk(db, hash2, "event", 2_i64, 0, 100)

        # Search with filter
        filters = Memo::Search::Filters.new(source_type: "document")
        results = Memo::Search.semantic(
          db: db,
          embedding: embedding,
          service_id: service_id,
          filters: filters
        )

        results.size.should eq(1)
        results[0].source_type.should eq("document")
      end
    end

    it "only returns results from same service" do
      with_test_db do |db|
        service1_id = Memo::Storage.register_service(
          db: db,
          provider: "openai",
          model: "text-embedding-3-small",
          version: nil,
          dimensions: 8,
          max_tokens: 8191
        )

        service2_id = Memo::Storage.register_service(
          db: db,
          provider: "openai",
          model: "text-embedding-3-large",
          version: nil,
          dimensions: 8,
          max_tokens: 8191
        )

        embedding = Array.new(8) { |i| i.to_f64 }

        # Store embeddings from different services
        hash1 = Memo::Storage.compute_hash("text1")
        Memo::Storage.store_embedding(db, hash1, embedding, 10, service1_id)
        Memo::Storage.create_chunk(db, hash1, "document", 1_i64, 0, 100)

        hash2 = Memo::Storage.compute_hash("text2")
        Memo::Storage.store_embedding(db, hash2, embedding, 10, service2_id)
        Memo::Storage.create_chunk(db, hash2, "document", 2_i64, 0, 100)

        # Search with service1
        results = Memo::Search.semantic(
          db: db,
          embedding: embedding,
          service_id: service1_id
        )

        results.size.should eq(1)
        results[0].source_id.should eq(1)
      end
    end

    it "respects min_score threshold" do
      with_test_db do |db|
        service_id = Memo::Storage.register_service(
          db: db,
          provider: "test",
          model: "test-model",
          version: nil,
          dimensions: 8,
          max_tokens: 1000
        )

        # Store embedding very different from query
        embedding = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0]
        hash = Memo::Storage.compute_hash("text")
        Memo::Storage.store_embedding(db, hash, embedding, 10, service_id)
        Memo::Storage.create_chunk(db, hash, "document", 1_i64, 0, 100)

        # Query with very different embedding
        query_embedding = [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]

        results = Memo::Search.semantic(
          db: db,
          embedding: query_embedding,
          service_id: service_id,
          min_score: 0.9  # High threshold
        )

        results.should be_empty
      end
    end

    it "increments match_count for returned results" do
      with_test_db do |db|
        service_id = Memo::Storage.register_service(
          db: db,
          provider: "test",
          model: "test-model",
          version: nil,
          dimensions: 8,
          max_tokens: 1000
        )

        embedding = Array.new(8) { |i| i.to_f64 }
        hash = Memo::Storage.compute_hash("text")
        Memo::Storage.store_embedding(db, hash, embedding, 10, service_id)
        chunk_id = Memo::Storage.create_chunk(db, hash, "document", 1_i64, 0, 100)

        # Search twice
        2.times do
          Memo::Search.semantic(
            db: db,
            embedding: embedding,
            service_id: service_id
          )
        end

        # Check match_count
        match_count = db.scalar(
          "SELECT match_count FROM memo_chunks WHERE id = ?",
          chunk_id
        ).as(Int64)

        match_count.should eq(2)
      end
    end
  end

  describe ".mark_as_read" do
    it "increments read_count for specified chunks" do
      with_test_db do |db|
        service_id = Memo::Storage.register_service(
          db: db,
          provider: "test",
          model: "test-model",
          version: nil,
          dimensions: 8,
          max_tokens: 1000
        )

        embedding = Array.new(8) { |i| i.to_f64 }
        hash = Memo::Storage.compute_hash("text")
        Memo::Storage.store_embedding(db, hash, embedding, 10, service_id)
        chunk_id = Memo::Storage.create_chunk(db, hash, "document", 1_i64, 0, 100)

        # Mark as read twice
        2.times do
          Memo::Search.mark_as_read(db, [chunk_id])
        end

        # Check read_count
        read_count = db.scalar(
          "SELECT read_count FROM memo_chunks WHERE id = ?",
          chunk_id
        ).as(Int64)

        read_count.should eq(2)
      end
    end
  end
end
