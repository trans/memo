require "json"

module Memo::CLI::Commands::Delete
  extend self

  def run(memo : Memo::Service, input : Hash(String, JSON::Any))
    count = memo.delete(
      source_id: input["source-id"].as_i64,
      source_type: input["source-type"]?.try(&.as_s)
    )

    output = Hash(String, JSON::Any).new
    output["deleted"] = JSON::Any.new(count.to_i64)
    output["source-id"] = JSON::Any.new(input["source-id"].as_i64)

    if source_type = input["source-type"]?.try(&.as_s)
      output["source-type"] = JSON::Any.new(source_type)
    end

    puts output.to_pretty_json
  end
end
