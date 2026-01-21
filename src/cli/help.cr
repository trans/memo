require "json"

module Memo::CLI::Help
  extend self

  # Generate help text for a command from its JSON Schema
  def for_command(name : String, schema : JSON::Any) : String
    String.build do |s|
      # Check if command has subcommands
      if subs = schema["subcommands"]?
        s << "Usage: memo #{name} <subcommand> [key=value ...]\n\n"
        s << "Subcommands:\n"
        subs.as_h.keys.each do |sub|
          s << "  #{sub}\n"
        end
        s << "\nRun 'memo #{name} <subcommand> --help' for subcommand help.\n"
      else
        s << "Usage: memo #{name} [key=value ...]\n\n"
        format_schema_args(s, schema)
        s << "\nAlternatively, pipe JSON to stdin:\n"
        s << "  echo '{\"key\": \"value\"}' | memo #{name} --stdin\n"
      end
    end
  end

  # Generate help text for a subcommand
  def for_subcommand(command : String, subcommand : String, schema : JSON::Any) : String
    String.build do |s|
      s << "Usage: memo #{command} #{subcommand} [key=value ...]\n\n"
      format_schema_args(s, schema)
      s << "\nAlternatively, pipe JSON to stdin:\n"
      s << "  echo '{\"key\": \"value\"}' | memo #{command} #{subcommand} --stdin\n"
    end
  end

  private def format_schema_args(s : String::Builder, schema : JSON::Any)
    props = schema["properties"]?
    if props.nil? || props.as_h.empty?
      s << "This command takes no arguments.\n"
    else
      properties = props.as_h
      required_arr = schema["required"]?
      required = required_arr ? required_arr.as_a.map(&.as_s) : [] of String

      s << "Arguments:\n"
      properties.each do |key, prop|
        type = prop["type"]?.try(&.as_s) || "string"
        desc = prop["description"]?.try(&.as_s) || ""
        default = prop["default"]?
        is_required = required.includes?(key)

        # Format: key=<type> (required)
        req_marker = is_required ? " (required)" : ""
        s << "  #{key}=<#{type}>#{req_marker}\n"

        # Description indented
        s << "      #{desc}\n" unless desc.empty?

        # Default value
        s << "      Default: #{default}\n" if default
      end
    end
  end

  # Generate global help text
  def global(commands : Array(String)) : String
    String.build do |s|
      s << "Usage: memo [options] <command> [args]\n\n"
      s << "Semantic search CLI for Memo.\n\n"
      s << "Global Options:\n"
      s << "  -d, --db=PATH       Database path (default: memo.db)\n"
      s << "  -s, --service=NAME  Service name to use\n"
      s << "  -f, --format=FMT    Provider format (openai, voyage, mock)\n"
      s << "  -k, --api-key=KEY   API key for embedding provider\n"
      s << "  -j, --json          Output as JSON (default: human-readable)\n"
      s << "  -h, --help          Show this help\n"
      s << "  -v, --version       Show version\n\n"
      s << "Commands:\n"
      commands.each do |cmd|
        s << "  #{cmd}\n"
      end
      s << "\nRun 'memo <command> --help' for command-specific help.\n"
    end
  end
end
