require "./spec_helper"

describe Memo::Projection do
  describe ".generate_orthogonal_vectors" do
    it "generates k vectors" do
      vectors = Memo::Projection.generate_orthogonal_vectors(8, 4)
      vectors.size.should eq(4)
    end

    it "generates vectors of correct dimension" do
      vectors = Memo::Projection.generate_orthogonal_vectors(16, 4)
      vectors.each do |vec|
        vec.size.should eq(16)
      end
    end

    it "generates unit vectors (magnitude ~1.0)" do
      vectors = Memo::Projection.generate_orthogonal_vectors(100, 8)
      vectors.each do |vec|
        magnitude = Math.sqrt(vec.sum { |v| v * v })
        (magnitude - 1.0).abs.should be < 0.0001
      end
    end

    it "generates orthogonal vectors (dot product ~0)" do
      vectors = Memo::Projection.generate_orthogonal_vectors(100, 8)

      # Check all pairs are orthogonal
      (0...vectors.size).each do |i|
        (i + 1...vectors.size).each do |j|
          dot = Memo::Projection.dot_product(vectors[i], vectors[j])
          dot.abs.should be < 0.0001
        end
      end
    end

    it "uses default k=8" do
      vectors = Memo::Projection.generate_orthogonal_vectors(16)
      vectors.size.should eq(Memo::Projection::K)
    end
  end

  describe ".dot_product" do
    it "computes dot product correctly" do
      a = [1.0, 2.0, 3.0]
      b = [4.0, 5.0, 6.0]
      # 1*4 + 2*5 + 3*6 = 4 + 10 + 18 = 32
      Memo::Projection.dot_product(a, b).should eq(32.0)
    end

    it "returns 0 for orthogonal vectors" do
      a = [1.0, 0.0, 0.0]
      b = [0.0, 1.0, 0.0]
      Memo::Projection.dot_product(a, b).should eq(0.0)
    end
  end

  describe ".normalize" do
    it "normalizes to unit length" do
      vec = [3.0, 4.0]  # magnitude = 5
      normalized = Memo::Projection.normalize(vec)
      normalized[0].should be_close(0.6, 0.0001)
      normalized[1].should be_close(0.8, 0.0001)
    end

    it "handles zero vector" do
      vec = [0.0, 0.0, 0.0]
      normalized = Memo::Projection.normalize(vec)
      normalized.should eq(vec)
    end
  end

  describe ".compute_projections" do
    it "computes dot products with projection vectors" do
      embedding = [1.0, 2.0, 3.0, 4.0]
      proj_vectors = [
        [1.0, 0.0, 0.0, 0.0],  # dot = 1
        [0.0, 1.0, 0.0, 0.0],  # dot = 2
        [0.0, 0.0, 1.0, 0.0],  # dot = 3
      ]

      projections = Memo::Projection.compute_projections(embedding, proj_vectors)
      projections.should eq([1.0, 2.0, 3.0])
    end
  end

  describe ".projection_distance_squared" do
    it "computes squared Euclidean distance" do
      a = [1.0, 2.0, 3.0]
      b = [4.0, 6.0, 3.0]
      # (1-4)^2 + (2-6)^2 + (3-3)^2 = 9 + 16 + 0 = 25
      Memo::Projection.projection_distance_squared(a, b).should eq(25.0)
    end

    it "returns 0 for identical vectors" do
      a = [1.0, 2.0, 3.0]
      Memo::Projection.projection_distance_squared(a, a).should eq(0.0)
    end
  end

  describe "storage operations" do
    describe ".store_projection_vectors and .get_projection_vectors" do
      it "round-trips projection vectors" do
        with_test_db do |db|
          service_id = Memo::Storage.register_service(
            db: db,
            provider: "test",
            model: "test-model",
            version: nil,
            dimensions: 8,
            max_tokens: 1000
          )

          vectors = Memo::Projection.generate_orthogonal_vectors(8)
          Memo::Projection.store_projection_vectors(db, service_id, vectors)

          retrieved = Memo::Projection.get_projection_vectors(db, service_id)
          retrieved.should_not be_nil

          retrieved_vectors = retrieved.not_nil!
          retrieved_vectors.size.should eq(vectors.size)

          vectors.each_with_index do |vec, i|
            vec.each_with_index do |val, j|
              # Float32 precision loss
              (retrieved_vectors[i][j] - val).abs.should be < 0.001
            end
          end
        end
      end

      it "returns nil for non-existent service" do
        with_test_db do |db|
          retrieved = Memo::Projection.get_projection_vectors(db, 999_i64)
          retrieved.should be_nil
        end
      end
    end

    describe ".store_projections and .get_projections" do
      it "round-trips projections" do
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

          # Store embedding first (foreign key constraint)
          Memo::Storage.store_embedding(db, hash, embedding, 10, service_id)

          projections = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
          Memo::Projection.store_projections(db, hash, projections)

          retrieved = Memo::Projection.get_projections(db, hash)
          retrieved.should_not be_nil

          retrieved_projections = retrieved.not_nil!
          retrieved_projections.size.should eq(projections.size)

          projections.each_with_index do |val, i|
            retrieved_projections[i].should be_close(val, 0.0001)
          end
        end
      end

      it "returns nil for non-existent hash" do
        with_test_db do |db|
          hash = Memo::Storage.compute_hash("nonexistent")
          retrieved = Memo::Projection.get_projections(db, hash)
          retrieved.should be_nil
        end
      end
    end
  end

  describe "search integration" do
    it "filters candidates by projection distance" do
      with_test_db do |db|
        service_id = Memo::Storage.register_service(
          db: db,
          provider: "test",
          model: "test-model",
          version: nil,
          dimensions: 8,
          max_tokens: 1000
        )

        # Generate projection vectors
        proj_vectors = Memo::Projection.generate_orthogonal_vectors(8)
        Memo::Projection.store_projection_vectors(db, service_id, proj_vectors)

        # Store embeddings with projections
        embeddings = [
          [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],  # Similar to query
          [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0],  # Very different
          [0.9, 0.1, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],  # Similar to query
        ]

        embeddings.each_with_index do |emb, i|
          text = "text#{i}"
          hash = Memo::Storage.compute_hash(text)
          Memo::Storage.store_embedding(db, hash, emb, 10, service_id)

          # Compute and store projections
          projections = Memo::Projection.compute_projections(emb, proj_vectors)
          Memo::Projection.store_projections(db, hash, projections)

          Memo::Storage.create_chunk(db, hash, "document", i.to_i64, 0, 100)
        end

        # Query with embedding similar to first and third
        query_embedding = [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]

        # Search with projection filtering (tight threshold)
        results = Memo::Search.semantic(
          db: db,
          embedding: query_embedding,
          service_id: service_id,
          limit: 10,
          min_score: 0.5,
          projection_vectors: proj_vectors,
          projection_threshold: 0.5  # Tight threshold to filter dissimilar
        )

        # Should find the similar embeddings but not the dissimilar one
        results.size.should be >= 1
        results.all? { |r| r.score >= 0.5 }.should be_true
      end
    end

    it "works without projection filtering" do
      with_test_db do |db|
        service_id = Memo::Storage.register_service(
          db: db,
          provider: "test",
          model: "test-model",
          version: nil,
          dimensions: 8,
          max_tokens: 1000
        )

        embedding = [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        hash = Memo::Storage.compute_hash("text")
        Memo::Storage.store_embedding(db, hash, embedding, 10, service_id)
        Memo::Storage.create_chunk(db, hash, "document", 1_i64, 0, 100)

        # Search without projection vectors (nil)
        results = Memo::Search.semantic(
          db: db,
          embedding: embedding,
          service_id: service_id,
          projection_vectors: nil
        )

        results.size.should eq(1)
      end
    end
  end
end
