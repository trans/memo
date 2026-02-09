module Memo::CLI::Commands::IndexText
  extend self

  def run(memo : Memo::Service, text : String, input : Hash(String, JSON::Any), json : Bool)
    source_type = Input.string(input, "source-type") || "text"
    source_id = Input.external_id(input, "source-id")

    count = memo.index(
      source_type: source_type,
      source_id: source_id,
      text: text,
      pair_id: Input.external_id(input, "pair-id"),
      parent_id: Input.external_id(input, "parent-id")
    )

    if json
      output = Hash(String, JSON::Any).new
      output["indexed"] = JSON::Any.new(count.to_i64)
      output["skipped"] = JSON::Any.new(count == -1)
      output["source-type"] = JSON::Any.new(source_type)
      if sid = source_id
        case sid
        when Int64
          output["source-id"] = JSON::Any.new(sid)
        when String
          output["source-id"] = JSON::Any.new(sid)
        end
      end
      puts output.to_pretty_json
    else
      source_display = source_id ? "#{source_type}:#{source_id}" : source_type
      if count == -1
        puts "Unchanged, skipped #{source_display}"
      else
        puts "Indexed #{count} chunk(s) for #{source_display}"
      end
    end
  end
end
