require "./spec_helper"

describe Memo::Storage do
  describe ".register_service" do
    it "creates new service and returns ID" do
      with_test_db do |db|
        service_id = Memo::Storage.register_service(
          db: db,
          name: nil,
          format: "openai",
          base_url: nil,
          model: "text-embedding-3-small",
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
          name: nil,
          format: "openai",
          base_url: nil,
          model: "text-embedding-3-small",
          
          dimensions: 1536,
          max_tokens: 8191
        )

        id2 = Memo::Storage.register_service(
          db: db,
          name: nil,
          format: "openai",
          base_url: nil,
          model: "text-embedding-3-small",
          
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
          name: nil,
          format: "openai",
          base_url: nil,
          model: "text-embedding-3-small",
          
          dimensions: 1536,
          max_tokens: 8191
        )

        id2 = Memo::Storage.register_service(
          db: db,
          name: nil,
          format: "openai",
          base_url: nil,
          model: "text-embedding-3-large",
          
          dimensions: 3072,
          max_tokens: 8191
        )

        id1.should_not eq(id2)
      end
    end
  end

  describe ".store_embedding" do
    it "stores embedding and returns inserted with rowid" do
      with_test_db do |db|
        service_id = Memo::Storage.register_service(
          db: db,
          name: nil,
          format: "mock",
          base_url: nil,
          model: "test-model",

          dimensions: 8,
          max_tokens: 1000
        )

        text = "Test text"
        hash = Memo::Storage.compute_hash(text)

        inserted, rowid = Memo::Storage.store_embedding(
          db: db,
          hash: hash,
          token_count: 10,
          service_id: service_id
        )

        inserted.should be_true
        rowid.should be > 0
      end
    end

    it "deduplicates by hash and returns same rowid" do
      with_test_db do |db|
        service_id = Memo::Storage.register_service(
          db: db,
          name: nil,
          format: "mock",
          base_url: nil,
          model: "test-model",

          dimensions: 8,
          max_tokens: 1000
        )

        text = "Test text"
        hash = Memo::Storage.compute_hash(text)

        # Store twice with same hash
        inserted1, rowid1 = Memo::Storage.store_embedding(db, hash, 10, service_id)
        inserted2, rowid2 = Memo::Storage.store_embedding(db, hash, 10, service_id)

        inserted1.should be_true
        inserted2.should be_false
        rowid1.should eq(rowid2)

        # Should only have one embedding
        count = db.scalar("SELECT COUNT(*) FROM memo_embeddings WHERE hash = ?", hash).as(Int64)
        count.should eq(1)
      end
    end
  end

  describe ".get_rowid" do
    it "returns rowid for existing embedding" do
      with_test_db do |db|
        service_id = Memo::Storage.register_service(
          db: db,
          name: nil,
          format: "mock",
          base_url: nil,
          model: "test-model",
          dimensions: 8,
          max_tokens: 1000
        )

        hash = Memo::Storage.compute_hash("test")
        _, rowid = Memo::Storage.store_embedding(db, hash, 10, service_id)

        found_rowid = Memo::Storage.get_rowid(db, hash, service_id)
        found_rowid.should eq(rowid)
      end
    end

    it "returns nil for non-existent hash" do
      with_test_db do |db|
        hash = Memo::Storage.compute_hash("nonexistent")
        rowid = Memo::Storage.get_rowid(db, hash, 1_i64)
        rowid.should be_nil
      end
    end
  end

  describe ".create_chunk" do
    it "creates chunk reference and returns ID" do
      with_test_db do |db|
        service_id = Memo::Storage.register_service(
          db: db,
          name: nil,
          format: "mock",
          base_url: nil,
          model: "test-model",
          
          dimensions: 8,
          max_tokens: 1000
        )

        text = "Test text"
        hash = Memo::Storage.compute_hash(text)

        Memo::Storage.store_embedding(db, hash, 10, service_id)

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
          name: nil,
          format: "mock",
          base_url: nil,
          model: "test-model",
          
          dimensions: 8,
          max_tokens: 1000
        )

        text = "Test text"
        hash = Memo::Storage.compute_hash(text)

        Memo::Storage.store_embedding(db, hash, 10, service_id)

        # Create two chunks referencing same embedding
        id1 = Memo::Storage.create_chunk(db, hash, "document", 1_i64, 0, 100)
        id2 = Memo::Storage.create_chunk(db, hash, "document", 2_i64, 0, 100)

        id1.should_not eq(id2)
      end
    end
  end

  describe "serialization" do
    it "round-trips embeddings correctly" do
      # Use normalized values in [-1, 1] range (as embedding models produce)
      original = [0.5, -0.3, 0.9, -0.5, 0.123, -0.456]

      blob = Memo::Storage.serialize_embedding(original)
      restored = Memo::Storage.deserialize_embedding(blob)

      # Int16 quantization means small differences are expected (~0.00003 per dim)
      restored.size.should eq(original.size)
      restored.each_with_index do |val, i|
        (val - original[i]).abs.should be < 0.001
      end
    end
  end
end
