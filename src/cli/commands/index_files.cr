require "json"

module Memo::CLI::Commands::IndexFiles
  extend self

  def run(memo : Memo::Service, input : Hash(String, JSON::Any), json : Bool)
    path = input["path"].as_s
    ignore_file = Input.string(input, "ignore-file") || ".gitignore"
    full = Input.bool(input, "full", false)
    dry_run = Input.bool(input, "dry-run", false)

    # Expand path
    root = Path.new(path).expand.to_s

    unless Dir.exists?(root)
      STDERR.puts "Error: Directory not found: #{root}"
      exit 1
    end

    if json
      results = [] of Hash(String, JSON::Any)

      indexed, skipped, total = memo.index_files(
        root: root,
        ignore_file: ignore_file,
        incremental: !full,
        dry_run: dry_run
      ) do |file_path, status|
        results << {
          "path"   => JSON::Any.new(file_path),
          "status" => JSON::Any.new(status.to_s),
        }
      end

      output = {
        "root"    => JSON::Any.new(root),
        "indexed" => JSON::Any.new(indexed.to_i64),
        "skipped" => JSON::Any.new(skipped.to_i64),
        "total"   => JSON::Any.new(total.to_i64),
        "dry_run" => JSON::Any.new(dry_run),
        "files"   => JSON::Any.new(results.map { |h| JSON::Any.new(h) }),
      }
      puts output.to_pretty_json
    else
      if dry_run
        puts "Dry run - files that would be indexed:"
        puts
      end

      indexed, skipped, total = memo.index_files(
        root: root,
        ignore_file: ignore_file,
        incremental: !full,
        dry_run: dry_run
      ) do |file_path, status|
        case status
        when :indexed
          puts "  + #{file_path}"
        when :skipped
          # Don't print skipped files by default (too noisy)
        when :would_index
          puts "  #{file_path}"
        end
      end

      puts
      if dry_run
        puts "Would index: #{total} files"
      else
        puts "Indexed: #{indexed}, Skipped: #{skipped}, Total: #{total}"
      end
    end
  end
end
