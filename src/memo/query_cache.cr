module Memo
  # LRU query embedding cache with optional DB persistence.
  #
  # Avoids repeated API calls for the same query text by caching
  # the embedding vector. Memory LRU is checked first (instant),
  # then DB (fast), then API (slow).
  #
  # Memory is bounded by max_entries (LRU eviction).
  # DB is bounded by max_db_entries (oldest evicted on prune).
  class QueryCache
    getter max_entries : Int32
    getter max_db_entries : Int32
    getter hits : Int64
    getter misses : Int64

    def initialize(
      @max_entries : Int32 = 10_000,
      @max_db_entries : Int32 = 100_000,
      @db : DB::Database? = nil,
      @service_id : Int64 = 0
    )
      @cache = {} of String => CacheEntry
      @order = Deque(String).new
      @hits = 0_i64
      @misses = 0_i64

      warm_from_db if @db && @max_entries > 0
    end

    # Look up a cached embedding for a query string.
    # Returns {embedding, token_count} or nil on miss.
    def get(query : String) : {Array(Float64), Int32}?
      key = query

      # Check memory LRU
      if entry = @cache[key]?
        touch(key)
        @hits += 1
        return {entry.embedding, entry.token_count}
      end

      # Check DB
      if db = @db
        row = db.memo_queries.get_query_cache(key, @service_id)
        if row
          embedding_blob, token_count = row
          embedding = Storage.deserialize_embedding(embedding_blob)
          put_memory(key, embedding, token_count)
          @hits += 1
          return {embedding, token_count}
        end
      end

      @misses += 1
      nil
    end

    # Store an embedding for a query string.
    def put(query : String, embedding : Array(Float64), token_count : Int32)
      key = query
      put_memory(key, embedding, token_count)
      put_db(key, embedding, token_count)
    end

    # Number of entries in memory cache
    def size : Int32
      @cache.size
    end

    # Clear all cached entries (memory and DB)
    def clear
      @cache.clear
      @order.clear
      @db.try { |db| db.memo_queries.clear_query_cache(@service_id) }
    end

    # Cache hit rate as a percentage
    def hit_rate : Float64
      total = @hits + @misses
      return 0.0 if total == 0
      (@hits.to_f64 / total * 100).round(1)
    end

    private struct CacheEntry
      getter embedding : Array(Float64)
      getter token_count : Int32

      def initialize(@embedding, @token_count)
      end
    end

    private def put_memory(key : String, embedding : Array(Float64), token_count : Int32)
      return if @max_entries <= 0

      if @cache.has_key?(key)
        touch(key)
        @cache[key] = CacheEntry.new(embedding, token_count)
      else
        evict if @cache.size >= @max_entries
        @cache[key] = CacheEntry.new(embedding, token_count)
        @order.push(key)
      end
    end

    private def put_db(key : String, embedding : Array(Float64), token_count : Int32)
      db = @db
      return unless db

      blob = Storage.serialize_embedding(embedding)
      db.memo_queries.upsert_query_cache(key, @service_id, blob, token_count, Time.utc.to_unix_ms)

      # Prune if over limit (delete oldest entries beyond max)
      count = db.memo_queries.count_query_cache(@service_id)
      if count > @max_db_entries
        db.memo_queries.prune_query_cache(@service_id, count - @max_db_entries)
      end
    end

    private def touch(key : String)
      @order.delete(key)
      @order.push(key)
    end

    private def evict
      if oldest = @order.shift?
        @cache.delete(oldest)
      end
    end

    private def warm_from_db
      db = @db
      return unless db

      rows = db.memo_queries.get_recent_query_cache(@service_id, @max_entries)
      rows.each do |key, embedding_blob, token_count|
        embedding = Storage.deserialize_embedding(embedding_blob)
        @cache[key] = CacheEntry.new(embedding, token_count)
        @order.push(key)
      end
    end
  end
end
