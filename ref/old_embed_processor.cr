require "./embed_pipeline"
require "./embed_pipeline/event_extractor"
require "./logger"
require "db"

module Copious
  # Immediate event embedding processor.
  #
  # Uses EmbedPipeline with EventExtractor for cursor-based tracking.
  #
  # ## Design
  #
  # Events are embedded immediately after each turn (no batching threshold).
  # All events get embedded and stored in meaning table.
  #
  # Search filtering (hist_search) uses time-based cutoff to exclude recent
  # events, so Historian can say "except current conversation".
  #
  module EmbedProcessor
    extend self

    # Embed pending events.
    #
    # Called after each conversation turn.
    # Embeds all events since last cursor, runs async.
    def maybe_embed_pending(
      db : DB::Database,
      api_key : String,
      project_path : String,
      embedder_config : Config::Agent,
      chunking_config : Config::Chunking
    )
      last_embedded = get_cursor(db)
      max_event_id = get_max_event_id(db)
      pending_count = max_event_id - last_embedded

      if pending_count > 0
        Logger.debug("embed_processor", "Embedding #{pending_count} pending events", project_path: project_path)
        spawn do
          embed_pending_events(db, api_key, project_path, embedder_config, chunking_config)
        end
      end
    end

    # Embed all events after cursor.
    #
    # This runs in a spawned fiber using the embedding pipeline.
    # On success, advances cursor. On failure, cursor stays same for retry.
    private def embed_pending_events(
      db : DB::Database,
      api_key : String,
      project_path : String,
      embedder_config : Config::Agent,
      chunking_config : Config::Chunking
    )
      begin
        # Use embedding pipeline with event extractor
        extractor = EmbedPipeline::EventExtractor.new(project_path, chunking_config)
        embedded_count = EmbedPipeline.run(db, api_key, extractor, project_path, embedder_config)

        if embedded_count > 0
          Logger.info("embed_processor", "Embedded #{embedded_count} event chunks", project_path: project_path)
        else
          Logger.debug("embed_processor", "No events to embed", project_path: project_path)
        end
      rescue ex
        Logger.error("embed_processor", "Embedding failed: #{ex.message}", project_path: project_path)
        Logger.debug("embed_processor", ex.inspect_with_backtrace, project_path: project_path)
        # Don't update cursor on failure - will retry next time
      end
    end

    # Get the cursor (last embedded event ID).
    #
    # Returns 0 if no cursor exists (first run).
    private def get_cursor(db : DB::Database) : Int64
      result = db.query_one?(
        "SELECT value FROM session_metadata WHERE key = ?",
        "last_embedded_event_id",
        as: String
      )

      if result
        result.to_i64
      else
        0_i64
      end
    end

    # Get the maximum event ID in the events table.
    #
    # Returns 0 if no events exist.
    private def get_max_event_id(db : DB::Database) : Int64
      result = db.query_one?("SELECT MAX(id) FROM events", as: Int64)

      if result
        result
      else
        0_i64
      end
    end
  end
end
