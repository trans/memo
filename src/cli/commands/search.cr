module Memo::CLI::Commands::Search
  extend self

  def run(memo : Memo::Service, input : Hash(String, JSON::Any), json : Bool)
    results = memo.search(
      query: input["query"].as_s,
      limit: Input.int(input, "limit") || 10,
      min_score: Input.float(input, "min-score") || 0.7,
      source_type: Input.string(input, "source-type"),
      source_id: Input.external_id(input, "source-id"),
      include_text: Input.bool(input, "include-text", true)
    )

    if json
      output = results.map do |r|
        result = Hash(String, JSON::Any).new
        result["chunk-id"] = JSON::Any.new(r.chunk_id)
        result["source-type"] = JSON::Any.new(r.source_type)
        result["internal-source-id"] = JSON::Any.new(r.internal_source_id)
        case sid = r.source_id
        when Int64
          result["source-id"] = JSON::Any.new(sid)
        when String
          result["source-id"] = JSON::Any.new(sid)
        when Bytes
          result["source-id"] = JSON::Any.new(sid.hexstring)
        end
        result["score"] = JSON::Any.new(r.score)
        result["offset"] = r.offset ? JSON::Any.new(r.offset.not_nil!.to_i64) : JSON::Any.new(nil)
        result["size"] = JSON::Any.new(r.size.to_i64)
        if text = r.text
          result["text"] = JSON::Any.new(text)
        end
        result
      end
      puts output.to_pretty_json
    else
      if results.empty?
        puts "No results found."
      else
        results.each_with_index do |r, i|
          # Display source_id or internal_source_id for memo-managed sources
          source_display = r.source_id || "##{r.internal_source_id}"
          puts "#{i + 1}. #{r.source_type}:#{source_display} (score: #{"%.3f" % r.score})"
          if text = r.text
            # Truncate long text for display
            display_text = text.size > 100 ? text[0, 100] + "..." : text
            display_text = display_text.gsub("\n", " ")
            puts "   #{display_text}"
          end
        end
        puts "\n#{results.size} result(s)"
      end
    end
  end
end
