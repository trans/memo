module Memo::CLI::Commands::Services
  def self.run(db : DB::Database, input : Hash(String, JSON::Any), json : Bool)
    services = Memo::ServiceProvider.list(db)

    if json
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
    else
      # Table output
      puts "%-30s %-8s %-26s %6s  %s" % ["NAME", "FORMAT", "MODEL", "DIM", ""]
      puts "-" * 80
      services.each do |s|
        default_marker = s.is_default? ? "*" : ""
        puts "%-30s %-8s %-26s %6d  %s" % [s.name, s.format, s.model, s.dimensions, default_marker]
      end
    end
  end
end

module Memo::CLI::Commands::ServiceUse
  def self.run(db : DB::Database, input : Hash(String, JSON::Any), json : Bool)
    name = input["name"].as_s

    if Memo::ServiceProvider.set_default(db, name)
      if json
        output = Hash(String, JSON::Any).new
        output["success"] = JSON::Any.new(true)
        output["default"] = JSON::Any.new(name)
        puts output.to_pretty_json
      else
        puts "Default service set to: #{name}"
      end
    else
      STDERR.puts "Service '#{name}' not found"
      exit 1
    end
  end
end

module Memo::CLI::Commands::ServiceCreate
  def self.run(db : DB::Database, input : Hash(String, JSON::Any), json : Bool)
    name = input["name"].as_s
    format = input["format"].as_s
    model = input["model"].as_s
    dimensions = input["dimensions"].as_i
    max_tokens = input["max-tokens"].as_i
    endpoint = Input.string(input, "endpoint")
    is_default = Input.bool(input, "default")

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

      if json
        output = Hash(String, JSON::Any).new
        output["name"] = JSON::Any.new(info.name)
        output["format"] = JSON::Any.new(info.format)
        output["model"] = JSON::Any.new(info.model)
        output["dimensions"] = JSON::Any.new(info.dimensions.to_i64)
        output["is_default"] = JSON::Any.new(info.is_default?)
        puts output.to_pretty_json
      else
        puts "Created service: #{info.name}"
        puts "  Format:     #{info.format}"
        puts "  Model:      #{info.model}"
        puts "  Dimensions: #{info.dimensions}"
        puts "  Default:    #{info.is_default? ? "yes" : "no"}"
      end
    rescue ex
      STDERR.puts "Error creating service: #{ex.message}"
      exit 1
    end
  end
end

module Memo::CLI::Commands::ServiceDelete
  def self.run(db : DB::Database, input : Hash(String, JSON::Any), json : Bool)
    name = input["name"].as_s
    force = Input.bool(input, "force")

    begin
      svc = Memo::ServiceProvider.get_by_name(db, name)
      unless svc
        STDERR.puts "Service '#{name}' not found"
        exit 1
      end

      if Memo::ServiceProvider.delete(db, svc.id, force: force)
        if json
          output = Hash(String, JSON::Any).new
          output["success"] = JSON::Any.new(true)
          output["deleted"] = JSON::Any.new(name)
          puts output.to_pretty_json
        else
          puts "Deleted service: #{name}"
        end
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
