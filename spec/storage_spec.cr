require "./spec_helper"

describe Memo::Storage do
  describe ".register_service" do
    it "creates new service and returns ID" do
      with_test_db do |db|
        service_id = Memo::Storage.register_service(
          db: db,
          provider: "openai",
          model: "text-embedding-3-small",
          version: nil,
          dimensions: 1536,
          max_tokens: 8191
        )

        service_id.should be > 0
      end
    end

    it "returns existing service ID for same provider/model/dimensions" do
      with_test_db do |db|
        id1 = Memo::Storage.register_service(
          db: db,
          provider: "openai",
          model: "text-embedding-3-small",
          version: nil,
          dimensions: 1536,
          max_tokens: 8191
        )

        id2 = Memo::Storage.register_service(
          db: db,
          provider: "openai",
          model: "text-embedding-3-small",
          version: nil,
          dimensions: 1536,
          max_tokens: 8191
        )

        id1.should eq(id2)
      end
    end

    it "creates separate services for different models" do
      with_test_db do |db|
        id1 = Memo::Storage.register_service(
          db: db,
          provider: "openai",
          model: "text-embedding-3-small",
          version: nil,
          dimensions: 1536,
          max_tokens: 8191
        )

        id2 = Memo::Storage.register_service(
          db: db,
          provider: "openai",
          model: "text-embedding-3-large",
          version: nil,
          dimensions: 3072,
          max_tokens: 8191
        )

        id1.should_not eq(id2)
      end
    end
  end

  describe ".store_embedding" do
    it "stores embedding and returns true" do
      with_test_db do |db|
        service_id = Memo::Storage.register_service(
          db: db,
          provider: "test",
          model: "test-model",
          version: nil,
          dimensions: 8,
          max_tokens: 1000
        )

        text = "Test text"
        hash = Memo::Storage.compute_hash(text)
        embedding = Array.new(8) { |i| i.to_f64 }

        result = Memo::Storage.store_embedding(
          db: db,
          hash: hash,
          embedding: embedding,
          token_count: 10,
          service_id: service_id
        )

        result.should be_true
      end
    end

    it "deduplicates by hash" do
      with_test_db do |db|
        service_id = Memo::Storage.register_service(
          db: db,
          provider: "test",
          model: "test-model",
          version: nil,
          dimensions: 8,
          max_tokens: 1000
        )

        text = "Test text"
        hash = Memo::Storage.compute_hash(text)
        embedding = Array.new(8) { |i| i.to_f64 }

        # Store twice with same hash
        Memo::Storage.store_embedding(db, hash, embedding, 10, service_id)
        Memo::Storage.store_embedding(db, hash, embedding, 10, service_id)

        # Should only have one embedding
        count = db.scalar("SELECT COUNT(*) FROM memo_embeddings WHERE hash = ?", hash).as(Int64)
        count.should eq(1)
      end
    end
  end

  describe ".get_embedding" do
    it "retrieves stored embedding" do
      with_test_db do |db|
        service_id = Memo::Storage.register_service(
          db: db,
          provider: "test",
          model: "test-model",
          version: nil,
          dimensions: 8,
          max_tokens: 1000
        )

        text = "Test text"
        hash = Memo::Storage.compute_hash(text)
        original_embedding = Array.new(8) { |i| i.to_f64 }

        Memo::Storage.store_embedding(db, hash, original_embedding, 10, service_id)

        retrieved = Memo::Storage.get_embedding(db, hash)
        retrieved.should_not be_nil
        retrieved.not_nil!.should eq(original_embedding)
      end
    end

    it "returns nil for non-existent hash" do
      with_test_db do |db|
        hash = Memo::Storage.compute_hash("nonexistent")
        retrieved = Memo::Storage.get_embedding(db, hash)
        retrieved.should be_nil
      end
    end
  end

  describe ".create_chunk" do
    it "creates chunk reference and returns ID" do
      with_test_db do |db|
        service_id = Memo::Storage.register_service(
          db: db,
          provider: "test",
          model: "test-model",
          version: nil,
          dimensions: 8,
          max_tokens: 1000
        )

        text = "Test text"
        hash = Memo::Storage.compute_hash(text)
        embedding = Array.new(8) { |i| i.to_f64 }

        Memo::Storage.store_embedding(db, hash, embedding, 10, service_id)

        chunk_id = Memo::Storage.create_chunk(
          db: db,
          hash: hash,
          source_type: "document",
          source_id: 42_i64,
          offset: 0,
          size: 100,
          pair_id: nil,
          parent_id: nil
        )

        chunk_id.should be > 0
      end
    end

    it "allows multiple chunks for same embedding" do
      with_test_db do |db|
        service_id = Memo::Storage.register_service(
          db: db,
          provider: "test",
          model: "test-model",
          version: nil,
          dimensions: 8,
          max_tokens: 1000
        )

        text = "Test text"
        hash = Memo::Storage.compute_hash(text)
        embedding = Array.new(8) { |i| i.to_f64 }

        Memo::Storage.store_embedding(db, hash, embedding, 10, service_id)

        # Create two chunks referencing same embedding
        id1 = Memo::Storage.create_chunk(db, hash, "document", 1_i64, 0, 100)
        id2 = Memo::Storage.create_chunk(db, hash, "document", 2_i64, 0, 100)

        id1.should_not eq(id2)
      end
    end
  end

  describe "serialization" do
    it "round-trips embeddings correctly" do
      original = [1.5, 2.7, 3.9, -0.5, 100.123, -200.456]

      blob = Memo::Storage.serialize_embedding(original)
      restored = Memo::Storage.deserialize_embedding(blob)

      # Float32 precision means small differences are expected
      restored.size.should eq(original.size)
      restored.each_with_index do |val, i|
        (val - original[i]).abs.should be < 0.001
      end
    end
  end
end
