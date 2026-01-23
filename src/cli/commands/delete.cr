module Memo::CLI::Commands::Delete
  extend self

  def run(memo : Memo::Service, input : Hash(String, JSON::Any), json : Bool)
    source_id = Input.external_id!(input, "source-id")
    source_type = Input.string(input, "source-type")

    count = memo.delete(
      source_id: source_id,
      source_type: source_type
    )

    if json
      output = Hash(String, JSON::Any).new
      output["deleted"] = JSON::Any.new(count.to_i64)
      case sid = source_id
      when Int64
        output["source-id"] = JSON::Any.new(sid)
      when String
        output["source-id"] = JSON::Any.new(sid)
      end
      if source_type
        output["source-type"] = JSON::Any.new(source_type)
      end
      puts output.to_pretty_json
    else
      source_desc = source_type ? "#{source_type}:#{source_id}" : "source #{source_id}"
      puts "Deleted #{count} chunk(s) from #{source_desc}"
    end
  end
end
