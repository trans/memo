module Memo
  module Config
    # Chunking configuration for text segmentation
    #
    # The app's preferred chunk sizes (must be <= service max_tokens)
    struct Chunking
      getter min_tokens : Int32              # Minimum chunk size before combining
      getter max_tokens : Int32              # Desired maximum chunk size
      getter no_chunk_threshold : Int32      # Don't chunk unless text exceeds this

      def initialize(
        @min_tokens : Int32 = 200,
        @max_tokens : Int32 = 2000,
        @no_chunk_threshold : Int32 = 1500
      )
      end
    end

    # AI embedding service configuration
    #
    # Describes the provider/model used for embeddings.
    # This gets stored in the services table to track which embeddings
    # belong to which vector space.
    struct EmbeddingService
      getter provider : String               # Provider name (e.g., "openai", "cohere")
      getter model : String                  # Model name (e.g., "text-embedding-3-small")
      getter version : String?               # Optional model version
      getter dimensions : Int32              # Vector dimensions (e.g., 1536)
      getter max_tokens : Int32              # Model's max tokens per chunk (hard limit)
      getter batch_size : Int32              # Max texts per batch embed call

      def initialize(
        @provider : String,
        @model : String,
        @dimensions : Int32,
        @max_tokens : Int32 = 8191,
        @version : String? = nil,
        @batch_size : Int32 = 100
      )
      end
    end

    # Search configuration
    struct Search
      getter default_limit : Int32
      getter default_min_score : Float64

      def initialize(
        @default_limit : Int32 = 10,
        @default_min_score : Float64 = 0.7
      )
      end
    end

    # Queue processing configuration
    #
    # Note: batch_size for embedding API calls comes from EmbeddingService.batch_size
    struct Queue
      getter max_retries : Int32

      def initialize(
        @max_retries : Int32 = 3
      )
      end
    end
  end
end
