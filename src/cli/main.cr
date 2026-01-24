require "jargon"
require "../memo"
require "./schema"
require "./input"
require "./commands/*"

module Memo::CLI
  VERSION = Memo::VERSION

  def self.run(args = ARGV)
    # Nested CLI for service subcommands
    service_cli = Jargon.new("service")
    service_cli.subcommand("list", Jargon.merge(SERVICE_LIST_SCHEMA, GLOBAL_SCHEMA))
    service_cli.subcommand("use", Jargon.merge(SERVICE_USE_SCHEMA, GLOBAL_SCHEMA))
    service_cli.subcommand("create", Jargon.merge(SERVICE_CREATE_SCHEMA, GLOBAL_SCHEMA))
    service_cli.subcommand("delete", Jargon.merge(SERVICE_DELETE_SCHEMA, GLOBAL_SCHEMA))
    service_cli.default_subcommand("list")

    # Main CLI
    cli = Jargon.new("memo")
    cli.subcommand("index", Jargon.merge(INDEX_SCHEMA, GLOBAL_SCHEMA))
    cli.subcommand("search", Jargon.merge(SEARCH_SCHEMA, GLOBAL_SCHEMA))
    cli.subcommand("like", Jargon.merge(LIKE_SCHEMA, GLOBAL_SCHEMA))
    cli.subcommand("build-vocab", Jargon.merge(BUILD_VOCAB_SCHEMA, GLOBAL_SCHEMA))
    cli.subcommand("delete", Jargon.merge(DELETE_SCHEMA, GLOBAL_SCHEMA))
    cli.subcommand("stats", Jargon.merge(STATS_SCHEMA, GLOBAL_SCHEMA))
    cli.subcommand("service", service_cli)

    # Handle --help and --version before parsing
    if args.includes?("--help") || args.includes?("-h")
      if args.size == 1 || (args.size == 2 && args[0].starts_with?("-"))
        puts help_text
        return
      end
    end

    if args.includes?("--version") || args.includes?("-v")
      puts "memo #{VERSION}"
      return
    end

    # Parse arguments
    result = cli.parse(args)

    # Handle subcommand-specific help
    if args.includes?("--help") || args.includes?("-h")
      puts cli.help
      return
    end

    unless result.valid?
      result.errors.each { |e| STDERR.puts "Error: #{e}" }
      exit 1
    end

    # Extract global options
    input = result.data.as_h
    db_path = input["db"]?.try(&.as_s) || "memo.db"
    service_name = input["service"]?.try(&.as_s)
    api_key = input["api-key"]?.try(&.as_s) || ENV["MEMO_API_KEY"]? || ENV["OPENAI_API_KEY"]? || ENV["VOYAGE_API_KEY"]?
    json_output = input["json"]?.try(&.as_bool) || false
    no_vocab = input["no-vocab"]?.try(&.as_bool) || false

    # Route to command handler
    case result.subcommand
    when "service list"
      db = Memo::Database.create(db_path)
      begin
        Commands::Services.run(db, input, json_output)
      ensure
        db.close
      end
    when "service use"
      db = Memo::Database.create(db_path)
      begin
        Commands::ServiceUse.run(db, input, json_output)
      ensure
        db.close
      end
    when "service create"
      db = Memo::Database.create(db_path)
      begin
        Commands::ServiceCreate.run(db, input, json_output)
      ensure
        db.close
      end
    when "service delete"
      db = Memo::Database.create(db_path)
      begin
        Commands::ServiceDelete.run(db, input, json_output)
      ensure
        db.close
      end
    when "index", "search", "like", "build-vocab", "delete", "stats"
      memo = Memo::Service.new(
        db_path: db_path,
        service: service_name,
        api_key: api_key,
        build_vocab: !no_vocab
      )
      begin
        case result.subcommand
        when "index"       then Commands::Index.run(memo, input, json_output)
        when "search"      then Commands::Search.run(memo, input, json_output)
        when "like"        then Commands::Like.run(memo, input, json_output)
        when "build-vocab" then Commands::BuildVocab.run(memo, input, json_output)
        when "delete"      then Commands::Delete.run(memo, input, json_output)
        when "stats"       then Commands::Stats.run(memo, input, json_output)
        end
      ensure
        memo.close
      end
    else
      STDERR.puts "Unknown command: #{result.subcommand || args.first?}"
      STDERR.puts "\nRun 'memo --help' for usage."
      exit 1
    end
  rescue ex
    STDERR.puts "Error: #{ex.message}"
    exit 1
  end

  private def self.help_text : String
    <<-HELP
    Usage: memo <command> [options]

    Semantic search CLI for Memo.

    Commands:
      index         Index text content
      search        Search indexed content
      like          Find similar words
      build-vocab   Build vocabulary from indexed content
      delete        Delete indexed content
      stats         Show statistics
      service       Manage embedding services

    Global Options:
      -d, --db=PATH       Database path (default: memo.db)
      -s, --service=NAME  Service name to use
      -k, --api-key=KEY   API key for embedding provider
      -j, --json          Output as JSON

    Run 'memo <command> --help' for command-specific help.

    Environment Variables:
      MEMO_API_KEY, OPENAI_API_KEY, VOYAGE_API_KEY
    HELP
  end
end

Memo::CLI.run
