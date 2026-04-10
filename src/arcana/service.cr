require "../memo"
require "json"

module Memo
  # Thin Arcana bus service wrapper around Memo::Service.
  #
  # Dispatches incoming requests by `action` field to the corresponding
  # Memo::Service method and returns JSON results.
  class ArcanaService
    SCHEMA = JSON.parse(%({"type":"object","required":["action"],"properties":{"action":{"type":"string","enum":["index","index_batch","search","delete","stats","help"]},"source_type":{"type":"string"},"source_id":{"type":"string"},"text":{"type":"string"},"documents":{"type":"array"},"query":{"type":"string"},"limit":{"type":"integer"},"min_score":{"type":"number"}}}))

    GUIDE = <<-GUIDE
    Memo semantic search service. Send an action with its parameters.

    Actions:
      index        — Index a document. Params: source_type, source_id, text
      index_batch  — Index multiple documents. Params: documents (array of {source_type, source_id, text})
      search       — Semantic search. Params: query, limit (default 10), min_score (default 0.7), source_type
      delete       — Delete a document. Params: source_id, source_type
      stats        — Get index statistics. No params.

    Examples:
      {"action": "index", "source_type": "note", "source_id": "42", "text": "Hello world"}
      {"action": "search", "query": "greeting", "limit": 5}
      {"action": "stats"}
    GUIDE

    getter memo : Memo::Service

    def initialize(@memo : Memo::Service)
    end

    def handle(data : JSON::Any) : JSON::Any
      action = data["action"]?.try(&.as_s?) || raise "missing action"

      case action
      when "index"
        handle_index(data)
      when "index_batch"
        handle_index_batch(data)
      when "search"
        handle_search(data)
      when "delete"
        handle_delete(data)
      when "stats"
        handle_stats
      when "help"
        JSON::Any.new({"guide" => JSON::Any.new(GUIDE)})
      else
        raise "unknown action: #{action}"
      end
    end

    private def handle_index(data : JSON::Any) : JSON::Any
      source_type = data["source_type"]?.try(&.as_s?) || raise "missing source_type"
      text = data["text"]?.try(&.as_s?) || raise "missing text"
      source_id = parse_source_id(data["source_id"]?)

      chunks = @memo.index(
        source_type: source_type,
        source_id: source_id,
        text: text,
      )
      JSON::Any.new({"ok" => JSON::Any.new(true), "chunks" => JSON::Any.new(chunks.to_i64)})
    end

    private def handle_index_batch(data : JSON::Any) : JSON::Any
      docs_json = data["documents"]?.try(&.as_a?) || raise "missing documents"

      docs = docs_json.map do |d|
        st = d["source_type"]?.try(&.as_s?) || raise "missing source_type in document"
        sid = parse_source_id(d["source_id"]?) || raise "missing source_id in document"
        txt = d["text"]?.try(&.as_s?) || raise "missing text in document"
        Memo::Document.new(source_type: st, source_id: sid, text: txt)
      end

      chunks = @memo.index_batch(docs)
      JSON::Any.new({"ok" => JSON::Any.new(true), "chunks" => JSON::Any.new(chunks.to_i64)})
    end

    private def handle_search(data : JSON::Any) : JSON::Any
      query = data["query"]?.try(&.as_s?) || raise "missing query"
      limit = data["limit"]?.try(&.as_i?) || 10
      min_score = data["min_score"]?.try(&.as_f?) || 0.7
      source_type = data["source_type"]?.try(&.as_s?)

      results, timings = @memo.search_with_timings(
        query: query,
        limit: limit.to_i32,
        min_score: min_score,
        source_type: source_type,
      )

      items = results.map do |r|
        h = {
          "score"       => JSON::Any.new(r.score),
          "text"        => JSON::Any.new(r.text || ""),
          "source_type" => JSON::Any.new(r.source_type),
          "source_id"   => json_any_from_external_id(r.source_id),
          "chunk_id"    => JSON::Any.new(r.chunk_id),
        } of String => JSON::Any
        JSON::Any.new(h)
      end

      JSON::Any.new({
        "ok"      => JSON::Any.new(true),
        "results" => JSON::Any.new(items),
        "timings" => JSON::Any.new({
          "embed_ms"  => JSON::Any.new(timings.embed_ms),
          "search_ms" => JSON::Any.new(timings.search_ms),
          "total_ms"  => JSON::Any.new(timings.total_ms),
          "cache_hit" => JSON::Any.new(timings.cache_hit),
        }),
      })
    end

    private def handle_delete(data : JSON::Any) : JSON::Any
      source_id = parse_source_id(data["source_id"]?) || raise "missing source_id"
      source_type = data["source_type"]?.try(&.as_s?)

      deleted = @memo.delete(source_id: source_id, source_type: source_type)
      JSON::Any.new({"ok" => JSON::Any.new(true), "deleted" => JSON::Any.new(deleted.to_i64)})
    end

    private def handle_stats : JSON::Any
      s = @memo.stats
      JSON::Any.new({
        "ok"                 => JSON::Any.new(true),
        "embeddings"         => JSON::Any.new(s.embeddings),
        "chunks"             => JSON::Any.new(s.chunks),
        "sources"            => JSON::Any.new(s.sources),
        "index_memory_bytes" => JSON::Any.new(s.index_memory_bytes.to_i64),
        "index_memory_mb"    => JSON::Any.new(s.index_memory_mb),
        "query_cache_size"   => JSON::Any.new(s.query_cache_size.to_i64),
      })
    end

    private def json_any_from_external_id(id : ExternalId?) : JSON::Any
      case id
      when Int64  then JSON::Any.new(id)
      when String then JSON::Any.new(id)
      else             JSON::Any.new(nil)
      end
    end

    private def parse_source_id(value : JSON::Any?) : ExternalId?
      return nil unless value
      raw = value.raw
      case raw
      when Int64  then raw
      when String then raw.to_i64? || raw
      else             nil
      end
    end
  end
end
