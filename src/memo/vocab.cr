module Memo
  # Vocabulary extraction and word-level semantic search
  module Vocab
    extend self

    # Common English stopwords to filter out
    STOPWORDS = Set{
      "a", "an", "and", "are", "as", "at", "be", "by", "for", "from",
      "has", "he", "in", "is", "it", "its", "of", "on", "that", "the",
      "to", "was", "were", "will", "with", "the", "this", "but", "they",
      "have", "had", "what", "when", "where", "who", "which", "why", "how",
      "all", "each", "every", "both", "few", "more", "most", "other", "some",
      "such", "no", "nor", "not", "only", "own", "same", "so", "than", "too",
      "very", "can", "just", "should", "now", "also", "been", "being", "do",
      "does", "did", "doing", "would", "could", "might", "must", "shall",
      "about", "above", "after", "again", "against", "any", "because", "before",
      "below", "between", "during", "into", "through", "under", "until", "up",
      "down", "out", "off", "over", "then", "once", "here", "there", "these",
      "those", "am", "if", "or", "while", "your", "you", "we", "our", "my",
      "me", "him", "her", "his", "them", "their", "she", "i", "us",
    }

    # Minimum word length to include
    MIN_WORD_LENGTH = 3

    # Maximum word length to include
    MAX_WORD_LENGTH = 30

    # Word frequency result from extraction
    struct WordFrequency
      getter word : String
      getter count : Int32

      def initialize(@word, @count)
      end
    end

    # Vocab search result
    struct Result
      getter word : String
      getter score : Float64
      getter frequency : Int32

      def initialize(@word, @score, @frequency)
      end
    end

    # Extract unique terms from text with frequency counts
    #
    # Tokenizes text, normalizes words, and filters:
    # - Stopwords
    # - Words shorter than MIN_WORD_LENGTH
    # - Words longer than MAX_WORD_LENGTH
    # - Numbers-only tokens
    #
    # Returns array of WordFrequency sorted by count (descending)
    def extract_terms(text : String) : Array(WordFrequency)
      word_counts = Hash(String, Int32).new(0)

      # Tokenize: split on non-word characters
      text.scan(/[\p{L}\p{N}]+/) do |match|
        word = match[0].downcase

        # Skip if too short or too long
        next if word.size < MIN_WORD_LENGTH
        next if word.size > MAX_WORD_LENGTH

        # Skip numbers-only
        next if word.matches?(/^\d+$/)

        # Skip stopwords
        next if STOPWORDS.includes?(word)

        word_counts[word] += 1
      end

      # Convert to array and sort by frequency
      word_counts.map { |word, count| WordFrequency.new(word, count) }
        .sort_by { |wf| -wf.count }
    end

    # Extract terms from multiple texts, combining frequencies
    def extract_terms_batch(texts : Array(String)) : Array(WordFrequency)
      word_counts = Hash(String, Int32).new(0)

      texts.each do |text|
        text.scan(/[\p{L}\p{N}]+/) do |match|
          word = match[0].downcase

          next if word.size < MIN_WORD_LENGTH
          next if word.size > MAX_WORD_LENGTH
          next if word.matches?(/^\d+$/)
          next if STOPWORDS.includes?(word)

          word_counts[word] += 1
        end
      end

      word_counts.map { |word, count| WordFrequency.new(word, count) }
        .sort_by { |wf| -wf.count }
    end

    # Search vocabulary for similar words
    #
    # Compares query embedding against stored word embeddings.
    # Returns results ranked by cosine similarity.
    def search(
      db : DB::Database,
      query_embedding : Array(Float64),
      service_id : Int64,
      limit : Int32 = 10,
      min_score : Float64 = 0.5
    ) : Array(Result)
      prefix = db.memo_table_prefix
      results = [] of Result

      db.query(
        "SELECT word, embedding, frequency FROM #{prefix}vocab WHERE service_id = ?",
        service_id
      ) do |rs|
        rs.each do
          word = rs.read(String)
          embedding_blob = rs.read(Bytes)
          frequency = rs.read(Int32)

          stored_embedding = Storage.deserialize_embedding(embedding_blob)
          score = cosine_similarity(query_embedding, stored_embedding)

          next if score < min_score

          result = Result.new(word, score, frequency)
          insert_sorted(results, result, limit)
        end
      end

      results
    end

    # Store a batch of word embeddings
    #
    # Words should be lowercase and already filtered.
    # Embeddings are stored with frequency counts.
    def store_batch(
      db : DB::Database,
      words : Array(String),
      embeddings : Array(Array(Float64)),
      frequencies : Array(Int32),
      service_id : Int64
    )
      prefix = db.memo_table_prefix
      now = Time.utc.to_unix_ms

      db.transaction do
        words.each_with_index do |word, idx|
          embedding_blob = Storage.serialize_embedding(embeddings[idx])

          db.exec(
            "INSERT OR REPLACE INTO #{prefix}vocab (word, service_id, embedding, frequency, created_at)
             VALUES (?, ?, ?, ?, ?)",
            word, service_id, embedding_blob, frequencies[idx], now
          )
        end
      end
    end

    # Clear all vocabulary for a service
    def clear(db : DB::Database, service_id : Int64)
      prefix = db.memo_table_prefix
      db.exec("DELETE FROM #{prefix}vocab WHERE service_id = ?", service_id)
    end

    # Get vocabulary count for a service
    def count(db : DB::Database, service_id : Int64) : Int64
      prefix = db.memo_table_prefix
      db.scalar(
        "SELECT COUNT(*) FROM #{prefix}vocab WHERE service_id = ?",
        service_id
      ).as(Int64)
    end

    # Calculate cosine similarity between two embeddings
    private def cosine_similarity(vec_a : Array(Float64), vec_b : Array(Float64)) : Float64
      return 0.0 if vec_a.size != vec_b.size

      dot_product = 0.0
      magnitude_a = 0.0
      magnitude_b = 0.0

      vec_a.size.times do |i|
        dot_product += vec_a[i] * vec_b[i]
        magnitude_a += vec_a[i] * vec_a[i]
        magnitude_b += vec_b[i] * vec_b[i]
      end

      magnitude_a = Math.sqrt(magnitude_a)
      magnitude_b = Math.sqrt(magnitude_b)

      return 0.0 if magnitude_a == 0.0 || magnitude_b == 0.0

      dot_product / (magnitude_a * magnitude_b)
    end

    # Insert result into sorted array, maintaining max size
    private def insert_sorted(results : Array(Result), new_result : Result, max_size : Int32)
      insert_idx = results.bsearch_index { |r| r.score < new_result.score } || results.size
      results.insert(insert_idx, new_result)
      results.pop if results.size > max_size
    end
  end
end
