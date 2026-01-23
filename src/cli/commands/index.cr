module Memo::CLI::Commands::Index
  extend self

  def run(memo : Memo::Service, input : Hash(String, JSON::Any), json : Bool)
    source_type = input["source-type"].as_s
    source_id = Input.external_id!(input, "source-id")

    count = memo.index(
      source_type: source_type,
      source_id: source_id,
      text: input["text"].as_s,
      pair_id: Input.external_id(input, "pair-id"),
      parent_id: Input.external_id(input, "parent-id")
    )

    if json
      output = Hash(String, JSON::Any).new
      output["indexed"] = JSON::Any.new(count.to_i64)
      output["source-type"] = JSON::Any.new(source_type)
      case sid = source_id
      when Int64
        output["source-id"] = JSON::Any.new(sid)
      when String
        output["source-id"] = JSON::Any.new(sid)
      end
      puts output.to_pretty_json
    else
      puts "Indexed #{count} chunk(s) for #{source_type}:#{source_id}"
    end
  end
end
