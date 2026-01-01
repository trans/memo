require "http/client"
require "json"

module Memo
  module Providers
    # OpenAI embedding provider
    #
    # Generates embeddings using OpenAI's embeddings API.
    class OpenAI
      include Base

      API_BASE = "https://api.openai.com/v1"

      getter api_key : String
      getter model : String

      def initialize(@api_key : String, @model : String = "text-embedding-3-small")
      end

      def embed_text(text : String) : {Array(Float64), Int32}
        result = embed_texts([text])
        {result.embeddings.first, result.token_counts.first}
      end

      def embed_texts(texts : Array(String)) : EmbedResult
        return EmbedResult.new([] of Array(Float64), [] of Int32, 0) if texts.empty?

        url = "#{API_BASE}/embeddings"
        body = {
          "model"           => @model,
          "input"           => texts,
          "encoding_format" => "float",
        }

        response = HTTP::Client.post(
          url,
          headers: HTTP::Headers{
            "Authorization" => "Bearer #{@api_key}",
            "Content-Type"  => "application/json",
          },
          body: body.to_json
        )

        unless response.success?
          raise Exception.new("OpenAI API error: #{response.status_code} - #{response.body}")
        end

        data = JSON.parse(response.body)
        embeddings = data["data"].as_a.map do |item|
          item["embedding"].as_a.map(&.as_f)
        end

        total_tokens = data["usage"]["total_tokens"].as_i
        avg_tokens = (total_tokens.to_f / texts.size).round.to_i
        token_counts = Array.new(texts.size, avg_tokens)

        EmbedResult.new(embeddings, token_counts, total_tokens)
      end
    end
  end
end
