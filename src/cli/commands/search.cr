require "json"

module Memo::CLI::Commands::Search
  extend self

  def run(memo : Memo::Service, input : Hash(String, JSON::Any), json : Bool)
    include_text = input["include-text"]?.try(&.as_bool?) || true

    results = memo.search(
      query: input["query"].as_s,
      limit: input["limit"]?.try(&.as_i) || 10,
      min_score: input["min-score"]?.try(&.as_f) || 0.7,
      source_type: input["source-type"]?.try(&.as_s),
      source_id: input["source-id"]?.try(&.as_i64),
      include_text: include_text
    )

    if json
      output = results.map do |r|
        result = {
          "chunk-id"    => JSON::Any.new(r.chunk_id),
          "source-type" => JSON::Any.new(r.source_type),
          "source-id"   => JSON::Any.new(r.source_id),
          "score"       => JSON::Any.new(r.score),
          "offset"      => r.offset ? JSON::Any.new(r.offset.not_nil!.to_i64) : JSON::Any.new(nil),
          "size"        => JSON::Any.new(r.size.to_i64),
        }
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
          puts "#{i + 1}. #{r.source_type}:#{r.source_id} (score: #{"%.3f" % r.score})"
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
