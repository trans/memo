module Memo
  # Text chunking for semantic search
  #
  # Splits large text into semantically meaningful chunks based on configurable limits:
  # - Text < no_chunk_threshold tokens: Keep whole (no chunking)
  # - Text > no_chunk_threshold tokens: Split on paragraph breaks (\n\n)
  # - Paragraphs > max_tokens: Further split on sentences
  # - Sentences < min_tokens: Combine with next sentence
  module Chunking
    extend self

    # Chunk text into segments based on configuration
    #
    # Returns array of chunk text strings
    def chunk_text(text : String, config : Config::Chunking) : Array(String)
      return [] of String if text.strip.empty?

      token_count = estimate_tokens(text)

      chunks = if token_count < config.no_chunk_threshold
                 # Keep whole
                 [text]
               else
                 # Split on paragraphs, then sentences if needed
                 paragraphs = split_paragraphs(text)
                 sentences = paragraphs.flat_map { |para| maybe_split_paragraph(para, config) }
                 combine_small_chunks(sentences, config)
               end

      chunks
    end

    # Estimate token count (rough approximation: chars / 4)
    def estimate_tokens(text : String) : Int32
      text.size // 4
    end

    # Split text on paragraph breaks (\n\n or more)
    private def split_paragraphs(text : String) : Array(String)
      text
        .split(/\n\n+/)
        .map(&.strip)
        .reject(&.empty?)
    end

    # Split paragraph on sentences if it's too large
    private def maybe_split_paragraph(paragraph : String, config : Config::Chunking) : Array(String)
      token_count = estimate_tokens(paragraph)

      if token_count > config.max_tokens
        split_sentences(paragraph)
      else
        [paragraph]
      end
    end

    # Split on sentence boundaries: . ! ? ; --
    private def split_sentences(text : String) : Array(String)
      text
        .split(/(?<=[.!?;])\s+|--/)
        .map(&.strip)
        .reject(&.empty?)
    end

    # Combine chunks that are too small
    private def combine_small_chunks(chunks : Array(String), config : Config::Chunking) : Array(String)
      return chunks if chunks.empty?

      result = [] of String
      i = 0

      while i < chunks.size
        chunk = chunks[i]

        if i == chunks.size - 1
          # Last chunk, keep it even if small
          result << chunk
          break
        end

        tokens = estimate_tokens(chunk)

        if tokens < config.min_tokens
          # Combine with next chunk
          next_chunk = chunks[i + 1]
          combined = "#{chunk} #{next_chunk}"
          chunks[i + 1] = combined
          # Don't add current chunk, continue with combined
        else
          # Keep chunk, move to next
          result << chunk
        end

        i += 1
      end

      result
    end
  end
end
