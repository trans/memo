require "json"

module Memo::CLI::Parser
  extend self

  # Parse key=value arguments into a JSON-compatible hash
  #
  # Examples:
  #   parse_args(["source-type=article", "source-id=123"])
  #   # => {"source-type" => "article", "source-id" => 123}
  def parse_args(args : Array(String)) : Hash(String, JSON::Any)
    result = {} of String => JSON::Any

    args.each do |arg|
      next unless arg.includes?("=")
      key, value = arg.split("=", 2)
      result[key] = coerce_value(value)
    end

    result
  end

  # Coerce string value to appropriate JSON type
  #
  # - "true"/"false" -> Bool
  # - Integer strings -> Int64
  # - Float strings -> Float64
  # - Everything else -> String
  def coerce_value(value : String) : JSON::Any
    case value
    when "true"
      JSON::Any.new(true)
    when "false"
      JSON::Any.new(false)
    when .matches?(/^-?\d+$/)
      JSON::Any.new(value.to_i64)
    when .matches?(/^-?\d+\.\d+$/)
      JSON::Any.new(value.to_f64)
    else
      JSON::Any.new(value)
    end
  end

  # Check if stdin is piped (not a TTY)
  def stdin_piped? : Bool
    !STDIN.tty?
  end

  # Read and parse JSON from stdin
  def read_stdin : Hash(String, JSON::Any)
    JSON.parse(STDIN.gets_to_end).as_h
  rescue ex : JSON::ParseException
    STDERR.puts "Error parsing JSON from stdin: #{ex.message}"
    exit 1
  end
end
