require "json"

module Memo::CLI::Commands::Index
  extend self

  def run(memo : Memo::Service, input : Hash(String, JSON::Any))
    count = memo.index(
      source_type: input["source-type"].as_s,
      source_id: input["source-id"].as_i64,
      text: input["text"].as_s,
      pair_id: input["pair-id"]?.try(&.as_i64),
      parent_id: input["parent-id"]?.try(&.as_i64)
    )

    output = {
      "indexed"     => count,
      "source-type" => input["source-type"].as_s,
      "source-id"   => input["source-id"].as_i64,
    }

    puts output.to_pretty_json
  end
end
