require "option_parser"
require "json"
require "jsonschema"
require "../memo"
require "./schema"
require "./parser"
require "./help"
require "./commands/*"

module Memo::CLI
  VERSION = Memo::VERSION

  def self.run(args = ARGV)
    db_path : String? = nil
    service : String? = nil
    format : String? = nil
    api_key : String? = nil
    json_output = false
    show_help = false
    show_version = false
    command_help = false

    # Find command position (first arg not starting with -)
    command_idx = args.index { |a| !a.starts_with?("-") }

    # Extract command and its args before parsing global options
    command : String? = nil
    subcommand : String? = nil
    command_args = [] of String

    if command_idx
      command = args[command_idx]
      command_args = args[(command_idx + 1)..]

      # Check for --help in command args BEFORE checking subcommand
      if command_args.includes?("--help") || command_args.includes?("-h")
        command_help = true
        command_args = command_args.reject { |a| a == "--help" || a == "-h" }
      end

      # Check for subcommand (for commands like "service list")
      subcommands = CLI.subcommands(command)
      if !subcommands.empty? && !command_args.empty?
        potential_sub = command_args.first
        if !potential_sub.starts_with?("-") && subcommands.includes?(potential_sub)
          subcommand = potential_sub
          command_args = command_args[1..]
        end
      end
    end

    # Parse global options (args before command)
    global_args = command_idx ? args[...command_idx] : args

    OptionParser.parse(global_args) do |p|
      p.banner = Help.global(CLI.commands)

      p.on("-d PATH", "--db=PATH", "Database path") { |v| db_path = v }
      p.on("-s NAME", "--service=NAME", "Service name") { |v| service = v }
      p.on("-f FORMAT", "--format=FORMAT", "Provider format (openai, voyage, mock)") { |v| format = v }
      p.on("-k KEY", "--api-key=KEY", "API key") { |v| api_key = v }
      p.on("-j", "--json", "Output as JSON") { json_output = true }
      p.on("-h", "--help", "Show help") { show_help = true }
      p.on("-v", "--version", "Show version") { show_version = true }

      p.invalid_option do |flag|
        STDERR.puts "Unknown option: #{flag}"
        STDERR.puts p
        exit 1
      end
    end

    # Handle version
    if show_version
      puts "memo #{VERSION}"
      return
    end

    # Environment variable fallbacks
    api_key ||= ENV["MEMO_API_KEY"]? || ENV["OPENAI_API_KEY"]? || ENV["VOYAGE_API_KEY"]?

    # Handle global help or no command
    if show_help || command.nil?
      puts Help.global(CLI.commands)
      return
    end

    # Validate command exists
    schema = CLI.schema(command)
    unless schema
      STDERR.puts "Unknown command: #{command}"
      STDERR.puts "\nAvailable commands: #{CLI.commands.join(", ")}"
      exit 1
    end

    # Handle command-specific help BEFORE applying default subcommand
    if command_help
      if subcommand
        sub_schema = CLI.subcommand_schema(command, subcommand)
        if sub_schema
          puts Help.for_subcommand(command, subcommand, sub_schema)
        end
      else
        puts Help.for_command(command, schema)
      end
      return
    end

    # Check if command has subcommands
    subcommands = CLI.subcommands(command)
    if !subcommands.empty?
      # Default subcommand is "list" if none provided
      subcommand ||= "list"

      unless subcommands.includes?(subcommand)
        STDERR.puts "Unknown subcommand: #{command} #{subcommand}"
        STDERR.puts "\nAvailable subcommands: #{subcommands.join(", ")}"
        exit 1
      end

      # Use subcommand schema
      schema = CLI.subcommand_schema(command, subcommand)
      unless schema
        STDERR.puts "No schema for: #{command} #{subcommand}"
        exit 1
      end
    end

    # Check for --json in command args (allow it after command too)
    if command_args.includes?("--json") || command_args.includes?("-j")
      json_output = true
    end

    # Get input: key=value args, or stdin JSON if --stdin flag is present
    use_stdin = command_args.includes?("--stdin")
    filtered_args = command_args.reject { |a| a.in?("--stdin", "--json", "-j") }

    input = if use_stdin
              Parser.read_stdin
            else
              Parser.parse_args(filtered_args)
            end

    # Validate against schema
    validator = JSONSchema.from_json(schema)
    result = validator.validate(JSON.parse(input.to_json))

    if result.status == :error
      STDERR.puts "Validation errors:"
      result.errors.each do |err|
        STDERR.puts "  #{err.context}: #{err.message}"
      end
      exit 1
    end

    final_db_path = db_path || "memo.db"

    # CLI uses standalone database mode (no table prefix)
    Memo.table_prefix = ""

    # Service management commands only need database access
    if command == "service"
      db = Memo::Database.create(final_db_path.as(String))
      begin
        case subcommand
        when "list"   then Commands::Services.run(db, input, json_output)
        when "use"    then Commands::ServiceUse.run(db, input, json_output)
        when "create" then Commands::ServiceCreate.run(db, input, json_output)
        when "delete" then Commands::ServiceDelete.run(db, input, json_output)
        end
      rescue ex
        STDERR.puts "Error: #{ex.message}"
        exit 1
      ensure
        db.close
      end
      return
    end

    # Other commands need full service initialization
    begin
      memo = Memo::Service.new(
        db_path: final_db_path.as(String),
        service: service,
        format: format,
        api_key: api_key,
        chunking_max_tokens: 50  # Use small default for mock compatibility
      )
    rescue ex
      STDERR.puts "Error initializing service: #{ex.message}"
      exit 1
    end

    # Dispatch to command handler
    begin
      case command
      when "index"  then Commands::Index.run(memo, input, json_output)
      when "search" then Commands::Search.run(memo, input, json_output)
      when "delete" then Commands::Delete.run(memo, input, json_output)
      when "stats"  then Commands::Stats.run(memo, input, json_output)
      else
        STDERR.puts "Command '#{command}' not implemented yet"
        exit 1
      end
    rescue ex
      STDERR.puts "Error: #{ex.message}"
      exit 1
    ensure
      memo.close
    end
  end
end

Memo::CLI.run
