require "../event"
require "../logger"

module Copious
  module Semantic
    module Chunking
      # Intelligent text chunking for semantic search embedding generation.
      #
      # Splits event text into semantically meaningful chunks based on configurable limits:
      # - Events < no_chunk_threshold tokens: Keep whole (no chunking)
      # - Events > no_chunk_threshold tokens: Split on paragraph breaks (\n\n)
      # - Paragraphs > max_chunk_tokens: Further split on sentences
      # - Sentences < min_chunk_tokens: Combine with next sentence
      #
      # Returns chunks with metadata to maintain order and source tracking.

      # Chunk represents a piece of text with source information
      struct Chunk
        property text : String
        property event_id : Int64
        property pair_id : Int64?
        property offset : Int32
        property size : Int32

        def initialize(@text, @event_id, @pair_id = nil, @offset = 0)
          @size = @text.size
        end

        def token_estimate : Int32
          Chunking.estimate_tokens(@text)
        end
      end

      # Extract chunks from a list of events using pair-based strategy
      #
      # This is the main entry point for chunking events for embedding.
      # It handles:
      # - Request events (user_message, tool_use): Skip (will be chunked with response)
      # - Response events (agent_response, tool_result): Find pair and chunk together
      # - Standalone events: Chunk individually
      def self.extract_chunks(events : Array(Event::Data), chunking_config : Config::Chunking, pair_context : Bool = true) : Array(Chunk)
        return [] of Chunk if events.empty?

        chunks = [] of Chunk

        events.each do |event|
          if pair_context
            event_chunks = chunk_event_pair_or_individual(event, events, chunking_config)
          else
            event_chunks = chunk_event(event, chunking_config)
          end

          chunks.concat(event_chunks)
        end

        chunks
      end

      # Chunk a single event into text segments
      def self.chunk_event(event : Event::Data, chunking_config : Config::Chunking) : Array(Chunk)
        text = extract_text(event)

        return [] of Chunk if text.empty?

        chunk_texts = chunk_text(text, chunking_config)

        chunk_texts.map_with_index do |chunk_text, idx|
          Chunk.new(chunk_text, event.id, event.pair_id, idx * chunking_config.max_tokens)
        end
      end

      # Chunk an event using pair-based strategy if applicable
      #
      # - Request events (user_message, tool_use): Skip (return empty)
      # - Response events (agent_response, tool_result): Find pair and chunk together
      # - Standalone events: Chunk individually
      def self.chunk_event_pair_or_individual(event : Event::Data, events : Array(Event::Data), chunking_config : Config::Chunking) : Array(Chunk)
        case event.type
        # Request events: Skip (will be chunked when response is processed)
        when Event::Type::UserMessage, Event::Type::ToolUse
          [] of Chunk

        # Response events: Try to find pair
        when Event::Type::AgentResponse, Event::Type::ToolResult
          if event.pair_id
            paired_event = events.find { |e| e.id == event.pair_id }

            if paired_event
              chunk_event_pair(paired_event, event, chunking_config)
            else
              Logger.warn("chunking", "Paired request event not found (id=#{event.pair_id}), chunking individually")
              chunk_event(event, chunking_config)
            end
          else
            Logger.warn("chunking", "Response event has no pair_id (id=#{event.id}), chunking individually")
            chunk_event(event, chunking_config)
          end

        # Lifecycle and system events: Chunk individually
        else
          chunk_event(event, chunking_config)
        end
      end

      # Chunk a pair of events together for better semantic context
      #
      # Pairs provide richer context for semantic search:
      # - user_message + agent_response: Captures question-answer relationship
      # - tool_use + tool_result: Captures action-outcome relationship
      def self.chunk_event_pair(event1 : Event::Data, event2 : Event::Data, chunking_config : Config::Chunking) : Array(Chunk)
        text1 = extract_pair_text(event1, chunking_config)
        text2 = extract_pair_text(event2, chunking_config)

        combined_text = combine_pair_texts(text1, text2)

        return [] of Chunk if combined_text.empty?

        # Return single chunk with combined text
        [Chunk.new(combined_text, event2.id, event2.pair_id, 0)]
      end

      # Chunk arbitrary text into segments
      def self.chunk_text(text : String, chunking_config : Config::Chunking) : Array(String)
        token_count = estimate_tokens(text)

        chunks = if token_count < chunking_config.no_chunk_threshold
                   # Keep whole
                   [text]
                 else
                   # Split on paragraphs, then sentences if needed
                   paragraphs = split_paragraphs(text)
                   sentences = paragraphs.flat_map { |para| maybe_split_paragraph(para, chunking_config) }
                   combine_small_chunks(sentences, chunking_config)
                 end

        chunks
      end

      # Estimate token count (rough approximation: chars / 4)
      def self.estimate_tokens(text : String) : Int32
        text.size // 4
      end

      ## Private helper methods

      # Extract readable text content from event
      private def self.extract_text(event : Event::Data) : String
        case event.type
        when Event::Type::UserMessage, Event::Type::AgentResponse
          extract_content_from_data(event.data)

        when Event::Type::ToolResult
          if content = event.data["content"]?
            content.as_s? || ""
          else
            ""
          end

        when Event::Type::Lifecycle
          case event.subtype
          when "completed"
            event.data["summary"]?.try(&.as_s) || ""
          when "session_resumed"
            time_gap = event.data["time_gap_description"]?.try(&.as_s) || ""
            "Session resumed after #{time_gap}"
          when "session_ended"
            duration = event.data["session_duration_description"]?.try(&.as_s) || ""
            "Session ended, duration: #{duration}"
          else
            ""
          end

        when Event::Type::System
          if event.subtype == "outline_updated"
            node_id = event.data["node_id"]?.try(&.as_s) || ""
            change_type = event.data["change_type"]?.try(&.as_s) || "updated"
            "Outline #{change_type}: #{node_id}"
          else
            ""
          end

        else
          ""
        end
      end

      # Extract text content from data field
      private def self.extract_content_from_data(data : JSON::Any) : String
        if data.as_h?
          if content = data.as_h["content"]?
            content.as_s? || ""
          else
            ""
          end
        else
          ""
        end
      end

      # Split text on paragraph breaks (\n\n or more)
      private def self.split_paragraphs(text : String) : Array(String)
        text
          .split(/\n\n+/)
          .map(&.strip)
          .reject(&.empty?)
      end

      # Split paragraph on sentences if it's too large
      private def self.maybe_split_paragraph(paragraph : String, chunking_config : Config::Chunking) : Array(String)
        token_count = estimate_tokens(paragraph)

        if token_count > chunking_config.max_tokens
          split_sentences(paragraph)
        else
          [paragraph]
        end
      end

      # Split on sentence boundaries: . ! ? ; --
      private def self.split_sentences(text : String) : Array(String)
        text
          .split(/(?<=[.!?;])\s+|--/)
          .map(&.strip)
          .reject(&.empty?)
      end

      # Combine chunks that are too small
      private def self.combine_small_chunks(chunks : Array(String), chunking_config : Config::Chunking) : Array(String)
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

          if tokens < chunking_config.min_tokens
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

      ## Pair-based chunking helpers

      # Extract text from event with role/type labels for pair context
      private def self.extract_pair_text(event : Event::Data, chunking_config : Config::Chunking) : String
        case event.type
        when Event::Type::UserMessage
          content = extract_content_from_data(event.data)
          content.empty? ? "" : "User: #{content}"

        when Event::Type::AgentResponse
          content = extract_content_from_data(event.data)
          role_label = format_role_label(event.role)
          content.empty? ? "" : "#{role_label}: #{content}"

        when Event::Type::ToolUse
          tool_name = event.name
          params = format_tool_params(event.data)
          # Only generate text if we have a tool name or params
          if tool_name || !params.empty?
            name_str = tool_name || "unknown_tool"
            "Tool: #{name_str}(#{params})"
          else
            ""
          end

        when Event::Type::ToolResult
          content = event.data["content"]?.try(&.as_s) || ""
          is_error = event.data["is_error"]?.try(&.as_bool) || false

          # Only generate text if we have actual content
          if content.empty?
            ""
          elsif is_error
            # Keep full error messages (usually short and important)
            "Result: Error - #{content}"
          else
            # Truncate long successful results to prevent huge file contents
            truncated = truncate_text(content, chunking_config.max_tool_result_chars)
            "Result: #{truncated}"
          end

        when Event::Type::Lifecycle
          if event.subtype == "completed"
            summary = event.data["summary"]?.try(&.as_s) || ""
            summary.empty? ? "" : "Expert completed: #{summary}"
          else
            ""
          end

        else
          ""
        end
      end

      # Format role label for agent responses
      private def self.format_role_label(role : String) : String
        case role
        when "master"      then "Assistant"
        when "expert"      then "Expert"
        when "cartographer" then "Cartographer"
        when "historian"   then "Historian"
        when "librarian"   then "Librarian"
        else
          role.capitalize
        end
      end

      # Format tool parameters for display
      private def self.format_tool_params(data : JSON::Any) : String
        return "" unless data.as_h?

        data.as_h
          .reject { |k, _v| k == "content" }
          .map { |k, v| "#{k}: #{v}" }
          .join(", ")
      end

      # Combine two event texts with separator
      private def self.combine_pair_texts(text1 : String, text2 : String) : String
        if text1.empty? && text2.empty?
          ""
        elsif text1.empty?
          text2
        elsif text2.empty?
          text1
        else
          "#{text1}\n\n#{text2}"
        end
      end

      # Truncate text to max_chars, adding ellipsis if truncated
      private def self.truncate_text(text : String, max_chars : Int32) : String
        if text.size <= max_chars
          text
        else
          "#{text[0...max_chars]}... (truncated)"
        end
      end
    end
  end
end
