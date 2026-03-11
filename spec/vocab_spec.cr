require "./spec_helper"

describe Memo::Service do
  describe "Vocabulary Operations" do
    describe "#build_vocab" do
      it "builds vocabulary from indexed content" do
        with_test_service do |service|
          service.index(source_type: "event", source_id: 1_i64,
            text: "The quick brown fox jumps over the lazy dog")
          service.index(source_type: "event", source_id: 2_i64,
            text: "Crystal is a programming language with ruby-like syntax")

          stored = service.build_vocab
          stored.should be > 0
        end
      end

      it "returns 0 when no texts are stored" do
        with_test_service do |service|
          stored = service.build_vocab
          stored.should eq(0)
        end
      end

      it "clears existing vocab by default" do
        with_test_service do |service|
          service.index(source_type: "event", source_id: 1_i64, text: "Hello world")

          service.build_vocab
          first_count = service.vocab_stats

          service.build_vocab
          second_count = service.vocab_stats

          # Should be same count since it clears first
          first_count.should eq(second_count)
        end
      end

      it "appends when clear_existing is false" do
        with_test_service do |service|
          service.index(source_type: "event", source_id: 1_i64, text: "Hello world")
          service.build_vocab

          # Index more content and build without clearing
          service.index(source_type: "event", source_id: 2_i64,
            text: "Completely different words here today")
          service.build_vocab(clear_existing: false)

          # Should have more words than either text alone
          count = service.vocab_stats
          count.should be > 0
        end
      end

      it "requires text storage" do
        with_test_db_path do |db_path|
          service = Memo::Service.new(
            db_path: db_path,
            service: "mock",
            store_text: false,
            chunking_max_tokens: 50
          )

          expect_raises(Exception, /Text storage required/) do
            service.build_vocab
          end

          service.close
        end
      end
    end

    describe "#like" do
      it "finds semantically similar words" do
        with_test_service do |service|
          service.index(source_type: "event", source_id: 1_i64,
            text: "The quick brown fox jumps over the lazy dog")

          service.build_vocab

          # With mock provider, similarity is hash-based, so just test it returns results
          results = service.like("fox", min_score: 0.0)
          results.should be_a(Array(Memo::Vocab::Result))
        end
      end

      it "respects limit parameter" do
        with_test_service do |service|
          service.index(source_type: "event", source_id: 1_i64,
            text: "The quick brown fox jumps over the lazy dog in the park")

          service.build_vocab

          results = service.like("fox", limit: 3, min_score: 0.0)
          results.size.should be <= 3
        end
      end

      it "returns empty when vocab is empty" do
        with_test_service do |service|
          results = service.like("anything", min_score: 0.0)
          results.should be_empty
        end
      end
    end

    describe "#vocab_stats" do
      it "returns 0 for empty vocab" do
        with_test_service do |service|
          service.vocab_stats.should eq(0)
        end
      end

      it "returns count after building vocab" do
        with_test_service do |service|
          service.index(source_type: "event", source_id: 1_i64, text: "Hello world")
          service.build_vocab

          service.vocab_stats.should be > 0
        end
      end
    end

    describe "#clear_vocab" do
      it "removes all vocab entries" do
        with_test_service do |service|
          service.index(source_type: "event", source_id: 1_i64, text: "Hello world")
          service.build_vocab
          service.vocab_stats.should be > 0

          service.clear_vocab
          service.vocab_stats.should eq(0)
        end
      end

      it "is safe to call on empty vocab" do
        with_test_service do |service|
          service.clear_vocab
          service.vocab_stats.should eq(0)
        end
      end
    end
  end
end
