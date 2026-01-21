require "json"

module Memo::CLI::Commands::Index
  extend self

  def run(memo : Memo::Service, input : Hash(String, JSON::Any), json : Bool)
    source_type = input["source-type"].as_s
    source_id = input["source-id"].as_i64

    count = memo.index(
      source_type: source_type,
      source_id: source_id,
      text: input["text"].as_s,
      pair_id: input["pair-id"]?.try(&.as_i64),
      parent_id: input["parent-id"]?.try(&.as_i64)
    )

    if json
      output = {
        "indexed"     => count,
        "source-type" => source_type,
        "source-id"   => source_id,
      }
      puts output.to_pretty_json
    else
      puts "Indexed #{count} chunk(s) for #{source_type}:#{source_id}"
    end
  end
end
