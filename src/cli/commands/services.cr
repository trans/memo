module Memo::CLI::Commands::Services
  def self.run(db : DB::Database, input : Hash(String, JSON::Any))
    services = Memo::ServiceProvider.list(db)

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
  def self.run(db : DB::Database, input : Hash(String, JSON::Any))
    name = input["name"].as_s

    if Memo::ServiceProvider.set_default(db, name)
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
  def self.run(db : DB::Database, input : Hash(String, JSON::Any))
    name = input["name"].as_s
    format = input["format"].as_s
    model = input["model"].as_s
    dimensions = input["dimensions"].as_i
    max_tokens = input["max-tokens"].as_i
    endpoint = input["endpoint"]?.try(&.as_s)
    is_default = input["default"]?.try(&.as_bool) || false

    begin
      info = Memo::ServiceProvider.create(
        db: db,
        name: name,
        format: format,
        model: model,
        dimensions: dimensions,
        max_tokens: max_tokens,
        base_url: endpoint,
        is_default: is_default
      )

      output = Hash(String, JSON::Any).new
      output["name"] = JSON::Any.new(info.name)
      output["format"] = JSON::Any.new(info.format)
      output["model"] = JSON::Any.new(info.model)
      output["dimensions"] = JSON::Any.new(info.dimensions.to_i64)
      output["is_default"] = JSON::Any.new(info.is_default?)
      puts output.to_pretty_json
    rescue ex
      STDERR.puts "Error creating service: #{ex.message}"
      exit 1
    end
  end
end

module Memo::CLI::Commands::ServiceDelete
  def self.run(db : DB::Database, input : Hash(String, JSON::Any))
    name = input["name"].as_s
    force = input["force"]?.try(&.as_bool) || false

    begin
      svc = Memo::ServiceProvider.get_by_name(db, name)
      unless svc
        STDERR.puts "Service '#{name}' not found"
        exit 1
      end

      if Memo::ServiceProvider.delete(db, svc.id, force: force)
        output = Hash(String, JSON::Any).new
        output["success"] = JSON::Any.new(true)
        output["deleted"] = JSON::Any.new(name)
        puts output.to_pretty_json
      else
        STDERR.puts "Failed to delete service '#{name}'"
        exit 1
      end
    rescue ex
      STDERR.puts "Error: #{ex.message}"
      exit 1
    end
  end
end
