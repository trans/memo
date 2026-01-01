module Memo
  module Providers
    # Mock embedding provider for testing
    #
    # Generates deterministic 8-dimensional vectors based on text hash.
    # Does not make any external API calls.
    class Mock
      include Base

      def embed_text(text : String) : {Array(Float64), Int32}
        embedding = generate_deterministic_embedding(text)
        token_count = estimate_tokens(text)
        {embedding, token_count}
      end

      def embed_texts(texts : Array(String)) : EmbedResult
        embeddings = texts.map { |t| generate_deterministic_embedding(t) }
        token_counts = texts.map { |t| estimate_tokens(t) }
        total = token_counts.sum
        EmbedResult.new(embeddings, token_counts, total)
      end

      # Generate deterministic 8-dimensional embedding from text hash
      private def generate_deterministic_embedding(text : String) : Array(Float64)
        hash = text.hash.abs
        (0...8).map { |i| ((hash >> (i * 4)) & 0xF).to_f / 15.0 }.to_a
      end

      # Estimate tokens (rough approximation: 4 chars ≈ 1 token)
      private def estimate_tokens(text : String) : Int32
        (text.size / 4).to_i
      end
    end
  end
end
