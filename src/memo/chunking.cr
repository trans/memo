module Memo
  # Text chunking for semantic search
  #
  # Splits large text into semantically meaningful chunks based on configurable limits:
  # - Text < no_chunk_threshold tokens: Keep whole (no chunking)
  # - Text > no_chunk_threshold tokens: Split on paragraph breaks (\n\n)
  # - Paragraphs > max_tokens: Further split on sentences
  # - Sentences < min_tokens: Combine with next sentence
  #
  # Range-based approach:
  # - All operations track exact character positions in the original text
  # - No string searching or reconstruction - positions are computed during splitting
  # - Returned offset/size are exact character ranges for SQLite SUBSTR compatibility
  # - chunk_text is the exact slice: text[offset, size]
  module Chunking
    extend self

    # Internal: character range in original text
    private record Range, start_pos : Int32, end_pos : Int32 do
      def size : Int32
        end_pos - start_pos
      end

      def slice(text : String) : String
        text[start_pos, size]
      end
    end

    # Chunk text into segments based on configuration
    #
    # Returns array of tuples: {chunk_text, offset, size}
    # - chunk_text: Exact slice from original text (text[offset, size])
    # - offset: Character position in original text (0-indexed)
    # - size: Character length of chunk
    #
    # SQLite usage: SUBSTR(content, offset + 1, size) returns chunk_text exactly
    def chunk_text(text : String, config : Config::Chunking) : Array({String, Int32, Int32})
      # Find content boundaries (skip leading/trailing whitespace)
      content_start : Int32? = nil
      content_end : Int32 = 0

      # Find first and last non-whitespace characters
      text.each_char_with_index do |char, idx|
        if !char.whitespace?
          content_start ||= idx
          content_end = idx + 1
        end
      end

      # Return empty if no non-whitespace content
      return [] of {String, Int32, Int32} if content_start.nil?

      content_range = Range.new(content_start, content_end)
      ratio = config.tokens_per_byte
      content_text = content_range.slice(text)
      token_count = estimate_tokens(content_text, ratio)

      ranges = if token_count < config.no_chunk_threshold
                 # Keep whole content as single chunk
                 [content_range]
               else
                 # Split on paragraphs, then sentences if needed
                 para_ranges = split_paragraphs(text, content_range)
                 sentence_ranges = para_ranges.flat_map { |r| maybe_split_sentences(text, r, config, ratio) }
                 combine_small_ranges(text, sentence_ranges, config, ratio)
               end

      # Convert ranges to output tuples
      ranges.map do |range|
        chunk = range.slice(text)
        {chunk, range.start_pos, range.size}
      end
    end

    # Estimate token count using tokens_per_byte ratio
    def estimate_tokens(text : String, tokens_per_byte : Float64 = 0.25) : Int32
      (text.bytesize * tokens_per_byte).round.to_i
    end

    # Split on paragraph breaks (\n\n+), returning ranges of trimmed content
    private def split_paragraphs(text : String, content_range : Range) : Array(Range)
      ranges = [] of Range
      pos = content_range.start_pos
      end_pos = content_range.end_pos

      while pos < end_pos
        # Skip any leading whitespace/newlines at current position
        while pos < end_pos && text[pos].whitespace?
          pos += 1
        end
        break if pos >= end_pos

        # Find end of this paragraph (next \n\n or end of content)
        para_start = pos
        para_end = pos
        newline_count = 0

        while pos < end_pos
          char = text[pos]
          if char == '\n'
            newline_count += 1
            if newline_count >= 2
              # Found paragraph break - para_end is before the newlines
              break
            end
          elsif !char.whitespace?
            # Reset newline count on non-whitespace
            newline_count = 0
            para_end = pos + 1  # Include this character
          end
          pos += 1
        end

        # Add paragraph if non-empty
        if para_end > para_start
          ranges << Range.new(para_start, para_end)
        end

        # Skip past the paragraph break
        while pos < end_pos && text[pos] == '\n'
          pos += 1
        end
      end

      ranges
    end

    # Split paragraph on sentences if it's too large
    private def maybe_split_sentences(text : String, range : Range, config : Config::Chunking, ratio : Float64) : Array(Range)
      chunk_text = range.slice(text)
      token_count = estimate_tokens(chunk_text, ratio)

      if token_count > config.max_tokens
        split_sentences(text, range)
      else
        [range]
      end
    end

    # Split on sentence boundaries: . ! ? ; followed by whitespace
    private def split_sentences(text : String, range : Range) : Array(Range)
      ranges = [] of Range
      pos = range.start_pos
      end_pos = range.end_pos

      while pos < end_pos
        # Skip leading whitespace
        while pos < end_pos && text[pos].whitespace?
          pos += 1
        end
        break if pos >= end_pos

        # Find end of sentence
        sentence_start = pos
        sentence_end = pos

        while pos < end_pos
          char = text[pos]

          if char.in?('.', '!', '?', ';')
            # Potential sentence end - check if followed by whitespace or end
            next_pos = pos + 1
            if next_pos >= end_pos || text[next_pos].whitespace?
              sentence_end = next_pos
              pos = next_pos
              break
            end
          end

          if !char.whitespace?
            sentence_end = pos + 1
          end
          pos += 1
        end

        # If we hit end without finding sentence boundary, take rest
        if pos >= end_pos && sentence_end < end_pos
          # Find actual end (last non-whitespace)
          temp = end_pos - 1
          while temp > sentence_start && text[temp].whitespace?
            temp -= 1
          end
          sentence_end = temp + 1
        end

        # Add sentence if non-empty
        if sentence_end > sentence_start
          ranges << Range.new(sentence_start, sentence_end)
        end

        # Skip whitespace after sentence
        while pos < end_pos && text[pos].whitespace?
          pos += 1
        end
      end

      ranges.empty? ? [range] : ranges
    end

    # Combine ranges that are too small
    # Combined range spans from first chunk's start to last chunk's end
    private def combine_small_ranges(text : String, ranges : Array(Range), config : Config::Chunking, ratio : Float64) : Array(Range)
      return ranges if ranges.empty?

      result = [] of Range
      i = 0

      while i < ranges.size
        range = ranges[i]

        if i == ranges.size - 1
          # Last range, keep it even if small
          result << range
          break
        end

        tokens = estimate_tokens(range.slice(text), ratio)

        if tokens < config.min_tokens
          # Combine with next range - span from this start to next end
          next_range = ranges[i + 1]
          combined = Range.new(range.start_pos, next_range.end_pos)
          ranges[i + 1] = combined
          # Don't add current range, continue with combined
        else
          result << range
        end

        i += 1
      end

      result
    end
  end
end
