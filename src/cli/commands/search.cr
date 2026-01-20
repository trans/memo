require "json"

module Memo::CLI::Commands::Search
  extend self

  def run(memo : Memo::Service, input : Hash(String, JSON::Any))
    results = memo.search(
      query: input["query"].as_s,
      limit: input["limit"]?.try(&.as_i) || 10,
      min_score: input["min-score"]?.try(&.as_f) || 0.7,
      source_type: input["source-type"]?.try(&.as_s),
      source_id: input["source-id"]?.try(&.as_i64),
      include_text: input["include-text"]?.try(&.as_bool?) || false
    )

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
  end
end
