require "../src/arcana/service"
require "../src/memo/pg"
require "http/web_socket"
require "json"

# Memo Arcana Bus Service
#
# Connects to an Arcana server via WebSocket and exposes Memo's
# core API as a multi-namespace bus service. Each namespace (ns)
# is an isolated embedding space with its own DB and USearch index.
#
# Environment variables:
#   ARCANA_HOST           — Arcana server host (default: 127.0.0.1)
#   ARCANA_PORT           — Arcana server port (default: 19118)
#   MEMO_NAMESPACES       — Path to namespaces config (default: /etc/memo/namespaces.yaml)

# ANSI color helpers
DIM    = "\e[2m"
BOLD   = "\e[1m"
RESET  = "\e[0m"
GREEN  = "\e[32m"
YELLOW = "\e[33m"
RED    = "\e[31m"
CYAN   = "\e[36m"
GRAY   = "\e[90m"

def log(msg : String)
  STDERR.puts "#{GRAY}#{Time.local.to_s("%H:%M:%S")}#{RESET} #{msg}"
end

def truncate(s : String, max : Int32 = 50) : String
  s.size > max ? "#{s[0, max]}…" : s
end

SENSITIVE_KEYS = Set{"api_key", "password", "secret", "token", "key"}

def sensitive?(key : String) : Bool
  k = key.downcase
  SENSITIVE_KEYS.any? { |s| k.includes?(s) }
end

def redact_db_url(url : String) : String
  # Redact password in postgres://user:PASSWORD@host/db style URLs
  url.gsub(/(:\/\/[^:]+:)[^@]+(@)/, "\\1***\\2")
end

def summarize(data : JSON::Any) : String
  return "" unless data.as_h?
  parts = [] of String
  data.as_h.each do |k, v|
    next if k == "action"
    val = if sensitive?(k)
            "***"
          else
            case raw = v.raw
            when String
              display = k == "db" ? redact_db_url(raw) : raw
              %("#{truncate(display, 40)}")
            when Array then "[#{raw.size}]"
            when Hash  then "{…}"
            else            raw.to_s
            end
          end
    parts << "#{k}=#{val}"
  end
  parts.join(" ")
end

arcana_host = ENV["ARCANA_HOST"]? || "127.0.0.1"
arcana_port = (ENV["ARCANA_PORT"]? || "19118").to_i
config_path = ENV["MEMO_NAMESPACES"]? || "/etc/memo/namespaces.yaml"

namespaces = Memo::Namespaces.new
if File.exists?(config_path)
  namespaces.load_config(config_path)
end

# Startup banner
STDERR.puts ""
STDERR.puts "#{BOLD}#{CYAN}memo-arcana#{RESET} #{DIM}— semantic search service#{RESET}"
STDERR.puts "#{DIM}┌──────────────────────────────────────────────────#{RESET}"
STDERR.puts "#{DIM}│#{RESET} config     #{DIM}│#{RESET} #{File.exists?(config_path) ? config_path : "(none)"}"
STDERR.puts "#{DIM}│#{RESET} namespaces #{DIM}│#{RESET} #{namespaces.configs.size} registered"
STDERR.puts "#{DIM}│#{RESET} bus        #{DIM}│#{RESET} #{arcana_host}:#{arcana_port}"
STDERR.puts "#{DIM}└──────────────────────────────────────────────────#{RESET}"

# Preload any namespaces flagged with preload: true
namespaces.configs.each_value do |c|
  log "#{DIM}registered#{RESET} ns=#{BOLD}#{c.ns}#{RESET} #{DIM}db=#{truncate(c.db, 40)} preload=#{c.preload}#{RESET}"
end
namespaces.preload_all
namespaces.services.each_key do |ns|
  log "#{GREEN}●#{RESET} preloaded #{BOLD}#{ns}#{RESET}"
end

handler = Memo::ArcanaService.new(namespaces)

ws_url = "ws://#{arcana_host}:#{arcana_port}/bus"
ws = HTTP::WebSocket.new(URI.parse(ws_url))

join_msg = {
  type:        "join",
  address:     "memo:rag",
  name:        "Memo RAG",
  description: "Multi-namespace retrieval-augmented generation service: semantic search, vector storage, embeddings",
  tags:        ["rag", "search", "vectors", "embeddings"],
}.to_json
ws.send(join_msg)

log "#{GREEN}●#{RESET} registered as #{BOLD}memo:rag#{RESET}, listening for requests"
STDERR.puts ""

ws.on_message do |msg|
  begin
    envelope = JSON.parse(msg)

    payload = envelope["payload"]?
    data = if payload && payload["_proto"]?
             payload["data"]? || JSON::Any.new(nil)
           else
             payload || JSON::Any.new(nil)
           end

    action = data["action"]?.try(&.as_s?) || "?"
    from = envelope["from"]?.try(&.as_s?) || "?"
    t_start = Time.instant

    if payload && payload["_intent"]?.try(&.as_s?) == "help"
      result_payload = JSON.parse(%({"_proto":"arcana/1","_status":"help","guide":#{Memo::ArcanaService::GUIDE.to_json},"schema":#{Memo::ArcanaService::SCHEMA.to_json}}))
      reply = {
        type:           "send",
        from:           "memo:rag",
        to:             envelope["reply_to"]?.try(&.as_s?) || envelope["from"]?.try(&.as_s?) || "",
        subject:        envelope["subject"]?.try(&.as_s?) || "",
        payload:        result_payload,
        correlation_id: envelope["correlation_id"]?.try(&.as_s?) || "",
      }.to_json
      ws.send(reply)
      next
    end

    result = handler.handle(data)
    elapsed_ms = (Time.instant - t_start).total_milliseconds.round(1)

    status_color = elapsed_ms > 500 ? YELLOW : GREEN
    summary = summarize(data)
    extra = ""
    if action == "search"
      if t = result["timings"]?
        cache = t["cache_hit"]?.try(&.as_bool?) ? "#{CYAN}cache#{RESET}" : ""
        n = result["results"]?.try(&.as_a?.try(&.size)) || 0
        extra = " #{DIM}→#{RESET} #{n} hit#{n == 1 ? "" : "s"} #{cache}"
      end
    elsif action == "stats" && result["embeddings"]?
      extra = " #{DIM}→#{RESET} #{result["embeddings"]} emb / #{result["chunks"]} chunks"
    elsif (action == "index" || action == "index_batch") && result["chunks"]?
      extra = " #{DIM}→#{RESET} #{result["chunks"]} chunks"
    end
    log "#{status_color}#{action.ljust(11)}#{RESET} #{DIM}#{from.ljust(12)}#{RESET} #{summary}#{extra} #{DIM}(#{elapsed_ms}ms)#{RESET}"

    result_payload = JSON::Any.new({
      "_proto"  => JSON::Any.new("arcana/1"),
      "_status" => JSON::Any.new("result"),
      "data"    => result,
    })

    reply_to = envelope["reply_to"]?.try(&.as_s?) || envelope["from"]?.try(&.as_s?) || ""
    next if reply_to.empty?

    reply = {
      type:           "send",
      from:           "memo:rag",
      to:             reply_to,
      subject:        envelope["subject"]?.try(&.as_s?) || "",
      payload:        result_payload,
      correlation_id: envelope["correlation_id"]?.try(&.as_s?) || "",
    }.to_json
    ws.send(reply)
  rescue ex
    if envelope
      error_payload = JSON::Any.new({
        "_proto"  => JSON::Any.new("arcana/1"),
        "_status" => JSON::Any.new("error"),
        "message" => JSON::Any.new(ex.message || "Unknown error"),
      })

      reply_to = envelope["reply_to"]?.try(&.as_s?) || envelope["from"]?.try(&.as_s?) || ""
      unless reply_to.empty?
        reply = {
          type:           "send",
          from:           "memo:rag",
          to:             reply_to,
          subject:        envelope["subject"]?.try(&.as_s?) || "",
          payload:        error_payload,
          correlation_id: envelope["correlation_id"]?.try(&.as_s?) || "",
        }.to_json
        ws.send(reply)
      end
    end

    log "#{RED}error#{RESET}      #{ex.message}"
  end
end

ws.on_close do |code, message|
  log "#{YELLOW}●#{RESET} disconnected (#{code}: #{message})"
  namespaces.close_all
  exit 0
end

Signal::INT.trap do
  STDERR.puts ""
  log "#{YELLOW}●#{RESET} shutting down"
  namespaces.close_all
  exit 0
end

Signal::TERM.trap do
  namespaces.close_all
  exit 0
end

ws.run
