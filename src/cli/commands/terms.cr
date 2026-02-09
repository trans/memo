module Memo::CLI::Commands::Terms
  extend self

  def run(memo : Memo::Service, input : Hash(String, JSON::Any), json : Bool)
    results = memo.like(
      query: input["query"].as_s,
      limit: Input.int(input, "limit") || 10,
      min_score: Input.float(input, "min-score") || 0.5
    )

    if json
      output = results.map do |r|
        {
          "word"      => JSON::Any.new(r.word),
          "score"     => JSON::Any.new(r.score),
          "frequency" => JSON::Any.new(r.frequency.to_i64),
        }
      end
      puts output.to_pretty_json
    else
      if results.empty?
        puts "No similar words found. Run 'memo build-vocab' first."
      else
        results.each do |r|
          puts "#{"%.2f" % r.score}  #{r.word}"
        end
      end
    end
  end
end
