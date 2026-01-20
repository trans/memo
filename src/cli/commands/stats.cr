require "json"

module Memo::CLI::Commands::Stats
  extend self

  def run(memo : Memo::Service, input : Hash(String, JSON::Any))
    stats = memo.stats

    output = {
      "embeddings" => stats.embeddings,
      "chunks"     => stats.chunks,
      "sources"    => stats.sources,
    }

    puts output.to_pretty_json
  end
end
