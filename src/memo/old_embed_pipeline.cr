require "./ai/openai"
require "./logger"
require "db"
require "digest/sha256"
require "memo"

module Copious
  # Unified content embedding pipeline.
  #
  # Generic pipeline: Extract → Embed → Store → Track
  #
  # ## Design
  #
  # All content types (events, outline sections, notes) follow the same flow:
  # 1. Extract chunks that need embedding (via Extractor)
  # 2. Generate embeddings and store (Memo::Service)
  # 3. Update progress tracking (via Extractor)
  #
  # Different content types implement Extractor interface to provide
  # type-specific extraction and progress tracking.
  module EmbedPipeline
    extend self

    # Run embedding pipeline with given extractor.
    #
    # Returns number of chunks embedded.
    def run(
      db : DB::Database,
      api_key : String,
      extractor : Extractor,
      project_path : String,
      embedder_config : Config::Agent
    ) : Int32
      # Create Memo service (handles embedding and storage)
      # Use max_tokens as chunking limit since Copious pre-chunks via DocumentParser
      embeddings_db_path = File.join(project_path, ".copious/embeddings.db")
      provider_str = embedder_config.provider.to_s
      dimensions = embedder_config.dimensions || 1536
      max_tokens = embedder_config.context_window

      memo = Memo::Service.new(
        db_path: embeddings_db_path,
        provider: provider_str,
        api_key: api_key,
        model: embedder_config.model,
        dimensions: dimensions,
        max_tokens: max_tokens,
        chunking_max_tokens: max_tokens  # Match provider limit
      )

      begin

        # 1. Extract chunks that need embedding
        chunks = extractor.extract(db)

        if chunks.empty?
          Logger.debug("embed_pipeline", "No chunks to embed for #{extractor.name}", project_path: project_path)
          return 0
        end

        Logger.info("embed_pipeline", "Embedding #{chunks.size} chunks for #{extractor.name}", project_path: project_path)

        # 2. Index each chunk (Memo handles embedding and storage)
        chunks.each do |chunk|
          # Determine source_type and source_id
          source_type, source_id = if chunk.event_id
                                     {"event", chunk.event_id.not_nil!}
                                   elsif chunk.artifact_id
                                     # Look up artifact kind (from Copious database)
                                     kind = db.query_one("SELECT kind FROM identity WHERE id = ?", chunk.artifact_id, as: String)
                                     {kind, chunk.artifact_id.not_nil!}
                                   else
                                     raise "Chunk must have event_id or artifact_id"
                                   end

          # Index via Memo::Service (includes pair_id)
          memo.index(
            source_type: source_type,
            source_id: source_id,
            text: chunk.text,
            pair_id: chunk.pair_id,
            parent_id: nil  # Copious doesn't use parent_id yet
          )

          Logger.debug("embed_pipeline", "Stored chunk for #{source_type}:#{source_id}", project_path: project_path)
        end

        # 3. Update progress tracking
        extractor.update_progress(db, chunks)

        Logger.info("embed_pipeline", "Completed embedding #{chunks.size} chunks for #{extractor.name}", project_path: project_path)

        chunks.size
      ensure
        # Always close Memo service
        memo.close
      end
    end

    # Content chunk for embedding.
    #
    # Contains text, hash, source reference (event or artifact), and position info.
    struct Chunk
      getter text : String
      getter hash : Bytes
      getter event_id : Int64?
      getter artifact_id : Int64?
      getter pair_id : Int64?
      getter offset : Int32
      getter size : Int32

      def initialize(
        @text : String,
        @hash : Bytes,
        @event_id : Int64? = nil,
        @artifact_id : Int64? = nil,
        @pair_id : Int64? = nil,
        @offset : Int32 = 0,
        @size : Int32 = 0
      )
      end
    end

    # Extractor interface for content types.
    #
    # Different content sources (events, outline, notes) implement this
    # to provide type-specific extraction and progress tracking.
    abstract class Extractor
      # Name for logging
      abstract def name : String

      # Extract chunks that need embedding.
      #
      # Should return only new/changed content, using appropriate strategy:
      # - Events: cursor-based (everything after last embedded)
      # - Outline/Notes: hash-based (only changed content)
      abstract def extract(db : DB::Database) : Array(Chunk)

      # Update progress tracking after successful embedding.
      #
      # - Events: update cursor to latest event ID
      # - Outline/Notes: no-op (hash tracking is automatic via cite table)
      abstract def update_progress(db : DB::Database, chunks : Array(Chunk))
    end
  end
end
