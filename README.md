# Memo

Semantic search and vector storage library for Crystal.

## Features

- **Text chunking** - Smart segmentation into optimal-sized pieces
- **Embedding storage** - Deduplication by content hash, service tracking
- **Similarity search** - Cosine similarity with filtering
- **RRF fusion** - Combine multiple search strategies

## Installation

Add to your `shard.yml`:

```yaml
dependencies:
  memo:
    github: trans/memo
```

Then run `shards install`.

## Quick Start

```crystal
require "memo"

# Create service (manages DB and embeddings)
memo = Memo::Service.new(
  db_path: "app.db",
  provider: "openai",
  api_key: ENV["OPENAI_API_KEY"]
)

# Index a document
memo.index(
  source_type: "document",
  source_id: 42_i64,
  text: "Your document text here..."
)

# Search
results = memo.search(query: "search query", limit: 10)
results.each do |r|
  puts "#{r.source_type}:#{r.source_id} (score: #{r.score})"
end
```

## API

### `Memo::Service`

The main API. Handles database lifecycle, chunking, and embeddings.

```crystal
# Initialize
memo = Memo::Service.new(
  db_path: "app.db",           # SQLite database path
  provider: "openai",          # Embedding provider
  api_key: "sk-...",           # API key for provider
  model: nil,                  # Optional: override default model
  chunking_max_tokens: 512     # Optional: max tokens per chunk
)

# Index text (automatic chunking and embedding)
memo.index(
  source_type: "document",
  source_id: 123_i64,
  text: "Long text to index...",
  pair_id: nil,      # Optional: related source
  parent_id: nil     # Optional: hierarchical parent
)

# Search
results = memo.search(
  query: "search query",
  limit: 10,
  min_score: 0.7,
  source_type: nil,  # Optional: filter by type
  source_id: nil,    # Optional: filter by ID
  pair_id: nil,      # Optional: filter by pair
  parent_id: nil     # Optional: filter by parent
)

# Track usage
memo.mark_as_read(chunk_ids: [1_i64, 2_i64])
```

### Search Results

```crystal
struct SearchResult
  getter chunk_id : Int64
  getter source_type : String
  getter source_id : Int64
  getter score : Float64
  getter pair_id : Int64?
  getter parent_id : Int64?
end
```

## Providers

Currently supported:
- `openai` - OpenAI text-embedding-3-small (default)
- `mock` - Deterministic embeddings for testing

## Architecture

See [DESIGN.md](DESIGN.md) for detailed architecture documentation.

## License

MIT
