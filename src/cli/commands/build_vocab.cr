require "json"

module Memo::CLI::Commands::BuildVocab
  extend self

  def run(memo : Memo::Service, input : Hash(String, JSON::Any), json : Bool)
    batch_size = Input.int(input, "batch-size") || 2000
    no_clear = Input.bool(input, "no-clear", false)

    word_count = memo.build_vocab(
      batch_size: batch_size,
      clear_existing: !no_clear
    )

    if json
      output = {
        "words_stored" => word_count,
        "service"      => memo.service_name,
      }
      puts output.to_pretty_json
    else
      puts "Built vocabulary: #{word_count} words"
    end
  end
end
