require "json"

module Memo::CLI::Commands::Stats
  extend self

  def run(memo : Memo::Service, input : Hash(String, JSON::Any), json : Bool)
    stats = memo.stats

    if json
      output = {
        "embeddings" => stats.embeddings,
        "chunks"     => stats.chunks,
        "sources"    => stats.sources,
      }
      puts output.to_pretty_json
    else
      puts "Embeddings: #{stats.embeddings}"
      puts "Chunks:     #{stats.chunks}"
      puts "Sources:    #{stats.sources}"
    end
  end
end
