require "json"

module Memo::CLI::Commands::IndexFiles
  extend self

  def run(memo : Memo::Service, files : Array(String), input : Hash(String, JSON::Any), json : Bool)
    recursive = Input.bool(input, "recursive", false)
    ignore_file = Input.string(input, "ignore-file") || ".gitignore"
    full = Input.bool(input, "full", false)
    dry_run = Input.bool(input, "dry-run", false)

    # Separate files from directories
    file_paths = [] of String
    dir_paths = [] of String

    files.each do |path|
      expanded = File.expand_path(path)
      if Dir.exists?(expanded)
        dir_paths << expanded
      elsif File.exists?(expanded)
        file_paths << expanded
      else
        STDERR.puts "Error: No such file or directory: #{path}"
        exit 1
      end
    end

    # Directories require -r flag
    unless dir_paths.empty? || recursive
      dir_paths.each do |d|
        STDERR.puts "Error: '#{d}' is a directory. Use -r to index recursively."
      end
      exit 1
    end

    if json
      run_json(memo, file_paths, dir_paths, recursive, ignore_file, full, dry_run)
    else
      run_text(memo, file_paths, dir_paths, recursive, ignore_file, full, dry_run)
    end
  end

  private def run_text(memo, file_paths, dir_paths, recursive, ignore_file, full, dry_run)
    indexed = 0
    skipped = 0
    total = 0

    if dry_run
      puts "Dry run - files that would be indexed:"
      puts
    end

    # Index explicit files
    unless file_paths.empty?
      root = Dir.current
      i, s, t = memo.index_file_list(
        paths: file_paths,
        root: root,
        incremental: !full,
        dry_run: dry_run
      ) do |file_path, status|
        case status
        when :indexed    then puts "  + #{file_path}"
        when :skipped    then nil # too noisy
        when :would_index then puts "  #{file_path}"
        end
      end
      indexed += i
      skipped += s
      total += t
    end

    # Recursively index directories
    dir_paths.each do |dir|
      i, s, t = memo.index_files(
        root: dir,
        ignore_file: ignore_file,
        incremental: !full,
        dry_run: dry_run
      ) do |file_path, status|
        case status
        when :indexed     then puts "  + #{file_path}"
        when :skipped     then nil # too noisy
        when :would_index then puts "  #{file_path}"
        end
      end
      indexed += i
      skipped += s
      total += t
    end

    puts
    if dry_run
      puts "Would index: #{total} files"
    else
      puts "Indexed: #{indexed}, Skipped: #{skipped}, Total: #{total}"
    end
  end

  private def run_json(memo, file_paths, dir_paths, recursive, ignore_file, full, dry_run)
    results = [] of Hash(String, JSON::Any)
    indexed = 0
    skipped = 0
    total = 0

    # Index explicit files
    unless file_paths.empty?
      root = Dir.current
      i, s, t = memo.index_file_list(
        paths: file_paths,
        root: root,
        incremental: !full,
        dry_run: dry_run
      ) do |file_path, status|
        results << {
          "path"   => JSON::Any.new(file_path),
          "status" => JSON::Any.new(status.to_s),
        }
      end
      indexed += i
      skipped += s
      total += t
    end

    # Recursively index directories
    dir_paths.each do |dir|
      i, s, t = memo.index_files(
        root: dir,
        ignore_file: ignore_file,
        incremental: !full,
        dry_run: dry_run
      ) do |file_path, status|
        results << {
          "path"   => JSON::Any.new(file_path),
          "status" => JSON::Any.new(status.to_s),
        }
      end
      indexed += i
      skipped += s
      total += t
    end

    output = {
      "indexed" => JSON::Any.new(indexed.to_i64),
      "skipped" => JSON::Any.new(skipped.to_i64),
      "total"   => JSON::Any.new(total.to_i64),
      "dry_run" => JSON::Any.new(dry_run),
      "files"   => JSON::Any.new(results.map { |h| JSON::Any.new(h) }),
    }
    puts output.to_pretty_json
  end
end
