module Memo
  module Providers
    # Internal provider interface for embedding services
    #
    # Implementations handle API communication with specific providers
    # (OpenAI, Cohere, etc.) and return embeddings in a standard format.
    module Base
      # Embed a single text
      #
      # Returns tuple of (embedding vector, token count)
      # input_type: "query" or "document" (used by Voyage AI for optimized embeddings)
      abstract def embed_text(text : String, input_type : String? = nil) : {Array(Float64), Int32}

      # Embed multiple texts in a batch
      #
      # Returns EmbedResult with embeddings and token counts
      # input_type: "query" or "document" (used by Voyage AI for optimized embeddings)
      abstract def embed_texts(texts : Array(String), input_type : String? = nil) : EmbedResult
    end

    # Result from batch embedding operation
    struct EmbedResult
      getter embeddings : Array(Array(Float64))
      getter token_counts : Array(Int32)
      getter total_tokens : Int32

      def initialize(@embeddings : Array(Array(Float64)), @token_counts : Array(Int32), @total_tokens : Int32)
      end
    end
  end
end
