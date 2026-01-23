module Memo::CLI::Commands::Like
  extend self

  def run(memo : Memo::Service, input : Hash(String, JSON::Any), json : Bool)
    results = memo.search(
      query: input["query"].as_s,
      limit: Input.int(input, "limit") || 10,
      min_score: Input.float(input, "min-score") || 0.5,
      include_text: true
    )

    if json
      output = results.compact_map do |r|
        next nil unless text = r.text
        {
          "text"  => JSON::Any.new(text),
          "score" => JSON::Any.new(r.score),
        }
      end
      puts output.to_pretty_json
    else
      if results.empty?
        puts "No similar concepts found."
      else
        results.each do |r|
          if text = r.text
            # Show score and text on one line
            puts "#{"%.2f" % r.score}  #{text.gsub("\n", " ").strip}"
          end
        end
      end
    end
  end
end
