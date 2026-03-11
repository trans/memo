require "./spec_helper"

describe Memo::Service do
  describe "Reindex Operations" do
    describe "#reindex (text storage)" do
      it "queues existing content for re-embedding" do
        with_test_service do |service|
          service.index(source_type: "event", source_id: 1_i64, text: "First document")
          service.index(source_type: "event", source_id: 2_i64, text: "Second document")

          queued = service.reindex("event")
          queued.should eq(2)

          stats = service.queue_stats
          stats.pending.should eq(2)
        end
      end

      it "content is searchable again after reindex + process_queue" do
        with_test_service do |service|
          service.index(source_type: "event", source_id: 1_i64, text: "Reindexable content")

          # Reindex queues items
          service.reindex("event")

          # Process the queue to re-embed
          service.process_queue

          # Should be searchable
          results = service.search(query: "Reindexable", min_score: 0.0)
          results.size.should be > 0
        end
      end

      it "returns 0 when no sources of that type exist" do
        with_test_service do |service|
          service.reindex("nonexistent").should eq(0)
        end
      end

      it "only reindexes the specified source type" do
        with_test_service do |service|
          service.index(source_type: "event", source_id: 1_i64, text: "Event doc")
          service.index(source_type: "idea", source_id: 2_i64, text: "Idea doc")

          queued = service.reindex("event")
          queued.should eq(1)

          # Idea should still be searchable without processing queue
          results = service.search(query: "Idea", source_type: "idea", min_score: 0.0)
          results.size.should eq(1)
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
            service.reindex("event")
          end

          service.close
        end
      end
    end

    describe "#reindex (with block)" do
      it "uses the block to fetch text" do
        with_test_service do |service|
          service.index(source_type: "event", source_id: 1_i64, text: "Original text")

          # Reindex with block providing new text
          queued = service.reindex("event") do |source_id|
            "Replacement text for #{source_id}"
          end
          queued.should eq(1)

          service.process_queue

          results = service.search(query: "Replacement", include_text: true, min_score: 0.0)
          results.size.should be > 0
        end
      end

      it "returns 0 when no sources exist" do
        with_test_service do |service|
          queued = service.reindex("nonexistent") { |_| "nope" }
          queued.should eq(0)
        end
      end
    end
  end
end
