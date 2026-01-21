module Memo::CLI::Commands::Services
  def self.run(memo : Memo::Service, input : Hash(String, JSON::Any))
    services = memo.list_services
    default_svc = memo.default_service

    output = services.map do |s|
      hash = Hash(String, JSON::Any).new
      hash["name"] = JSON::Any.new(s.name)
      hash["format"] = JSON::Any.new(s.format)
      hash["model"] = JSON::Any.new(s.model)
      hash["dimensions"] = JSON::Any.new(s.dimensions.to_i64)
      hash["max_tokens"] = JSON::Any.new(s.max_tokens.to_i64)
      hash["is_default"] = JSON::Any.new(s.is_default?)
      hash
    end

    puts output.to_pretty_json
  end
end

module Memo::CLI::Commands::ServiceUse
  def self.run(memo : Memo::Service, input : Hash(String, JSON::Any))
    name = input["name"].as_s

    if memo.set_default_service(name)
      output = Hash(String, JSON::Any).new
      output["success"] = JSON::Any.new(true)
      output["default"] = JSON::Any.new(name)
      puts output.to_pretty_json
    else
      STDERR.puts "Service '#{name}' not found"
      exit 1
    end
  end
end

module Memo::CLI::Commands::ServiceCreate
  def self.run(memo : Memo::Service, input : Hash(String, JSON::Any))
    name = input["name"].as_s
    format = input["format"].as_s
    model = input["model"].as_s
    dimensions = input["dimensions"].as_i
    max_tokens = input["max-tokens"].as_i
    is_default = input["default"]?.try(&.as_bool) || false

    begin
      info = memo.create_service(
        name: name,
        format: format,
        model: model,
        dimensions: dimensions,
        max_tokens: max_tokens
      )

      # Set as default if requested
      if is_default
        memo.set_default_service(name)
      end

      output = Hash(String, JSON::Any).new
      output["name"] = JSON::Any.new(info.name)
      output["format"] = JSON::Any.new(info.format)
      output["model"] = JSON::Any.new(info.model)
      output["dimensions"] = JSON::Any.new(info.dimensions.to_i64)
      output["is_default"] = JSON::Any.new(is_default)
      puts output.to_pretty_json
    rescue ex
      STDERR.puts "Error creating service: #{ex.message}"
      exit 1
    end
  end
end

module Memo::CLI::Commands::ServiceDelete
  def self.run(memo : Memo::Service, input : Hash(String, JSON::Any))
    name = input["name"].as_s
    force = input["force"]?.try(&.as_bool) || false

    begin
      if memo.delete_service(name, force: force)
        output = Hash(String, JSON::Any).new
        output["success"] = JSON::Any.new(true)
        output["deleted"] = JSON::Any.new(name)
        puts output.to_pretty_json
      else
        STDERR.puts "Service '#{name}' not found"
        exit 1
      end
    rescue ex
      STDERR.puts "Error: #{ex.message}"
      exit 1
    end
  end
end
