module Memo
  # Text chunking for semantic search
  #
  # Splits large text into semantically meaningful chunks based on configurable limits:
  # - Text < no_chunk_threshold tokens: Keep whole (no chunking)
  # - Text > no_chunk_threshold tokens: Split on paragraph breaks (\n\n)
  # - Paragraphs > max_tokens: Further split on sentences
  # - Sentences < min_tokens: Combine with next sentence
  #
  # Offset/size tracking:
  # - Offset is the character position in the original text where the chunk content starts
  # - Size is the character length of the span in the original text
  # - For combined chunks, the span covers from the first chunk's start to the last chunk's end
  # - This allows SUBSTR(content, offset + 1, size) to extract the original text span
  module Chunking
    extend self

    # Internal representation: chunk text with its span in original text
    private record Span, text : String, offset : Int32, size : Int32

    # Chunk text into segments based on configuration
    #
    # Returns array of tuples: {chunk_text, offset, size}
    # - chunk_text: The processed text (may be trimmed/normalized)
    # - offset: Character position in original text (0-indexed)
    # - size: Character length of span in original text
    #
    # Note: SUBSTR(original, offset + 1, size) returns the original span,
    # which may differ slightly from chunk_text due to whitespace normalization.
    def chunk_text(text : String, config : Config::Chunking) : Array({String, Int32, Int32})
      return [] of {String, Int32, Int32} if text.strip.empty?

      ratio = config.tokens_per_byte
      token_count = estimate_tokens(text, ratio)

      spans = if token_count < config.no_chunk_threshold
                # Keep whole - find the trimmed content's position
                trimmed = text.strip
                offset = text.index(trimmed) || 0
                [Span.new(trimmed, offset, trimmed.size)]
              else
                # Split on paragraphs, then sentences if needed
                para_spans = split_paragraphs_with_positions(text)
                sentence_spans = para_spans.flat_map { |span| maybe_split_paragraph_with_positions(span, config, ratio) }
                combine_small_spans(sentence_spans, config, ratio)
              end

      spans.map { |s| {s.text, s.offset, s.size} }
    end

    # Estimate token count using tokens_per_byte ratio
    def estimate_tokens(text : String, tokens_per_byte : Float64 = 0.25) : Int32
      (text.bytesize * tokens_per_byte).round.to_i
    end

    # Split text on paragraph breaks (\n\n or more), tracking positions
    private def split_paragraphs_with_positions(text : String) : Array(Span)
      result = [] of Span
      pos = 0

      # Split on double+ newlines
      text.split(/\n\n+/).each do |part|
        next if part.strip.empty?

        # Find where this part starts in original text
        part_start = text.index(part, pos)
        next unless part_start

        # Trim the part and find trimmed content position
        trimmed = part.strip
        trim_offset = part.index(trimmed) || 0

        result << Span.new(trimmed, part_start + trim_offset, trimmed.size)
        pos = part_start + part.size
      end

      result
    end

    # Split paragraph on sentences if it's too large, preserving positions
    private def maybe_split_paragraph_with_positions(span : Span, config : Config::Chunking, ratio : Float64) : Array(Span)
      token_count = estimate_tokens(span.text, ratio)

      if token_count > config.max_tokens
        split_sentences_with_positions(span)
      else
        [span]
      end
    end

    # Split on sentence boundaries, tracking positions relative to original text
    private def split_sentences_with_positions(span : Span) : Array(Span)
      result = [] of Span
      text = span.text
      base_offset = span.offset
      pos = 0

      # Split on sentence boundaries: . ! ? ; or --
      text.split(/(?<=[.!?;])\s+|--/).each do |part|
        next if part.strip.empty?

        # Find where this part starts in the span's text
        part_start = text.index(part, pos)
        next unless part_start

        # Trim and find trimmed content position
        trimmed = part.strip
        trim_offset = part.index(trimmed) || 0

        result << Span.new(trimmed, base_offset + part_start + trim_offset, trimmed.size)
        pos = part_start + part.size
      end

      result
    end

    # Combine spans that are too small
    # When combining, the span extends from first chunk's start to last chunk's end
    private def combine_small_spans(spans : Array(Span), config : Config::Chunking, ratio : Float64) : Array(Span)
      return spans if spans.empty?

      result = [] of Span
      i = 0

      while i < spans.size
        span = spans[i]

        if i == spans.size - 1
          # Last span, keep it even if small
          result << span
          break
        end

        tokens = estimate_tokens(span.text, ratio)

        if tokens < config.min_tokens
          # Combine with next span
          next_span = spans[i + 1]

          # Combined text uses space separator (for embedding)
          combined_text = "#{span.text} #{next_span.text}"

          # Combined span covers from this span's start to next span's end
          combined_offset = span.offset
          combined_end = next_span.offset + next_span.size
          combined_size = combined_end - combined_offset

          spans[i + 1] = Span.new(combined_text, combined_offset, combined_size)
          # Don't add current span, continue with combined
        else
          # Keep span, move to next
          result << span
        end

        i += 1
      end

      result
    end
  end
end
