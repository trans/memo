# Memo

Semantic search and vector storage library for Crystal.

## Features

- **Text chunking** - Smart segmentation into optimal-sized pieces
- **Embedding storage** - Deduplication by content hash
- **Similarity search** - Cosine similarity with filtering
- **Text storage** - Optional persistent text with LIKE and FTS5 full-text search
- **Projection filtering** - Fast candidate pre-filtering via random projections
- **External DB support** - ATTACH databases for custom filtering

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

# Create service with data directory
memo = Memo::Service.new(
  data_dir: "/var/data/memo",
  provider: "openai",
  api_key: ENV["OPENAI_API_KEY"]
)

# Index a document
memo.index(
  source_type: "article",
  source_id: 42_i64,
  text: "Your document text here..."
)

# Search
results = memo.search(query: "search query", limit: 10)
results.each do |r|
  puts "#{r.source_type}:#{r.source_id} (score: #{r.score})"
end

# Clean up
memo.close
```

## API

### `Memo::Service`

The main API. Handles database lifecycle, chunking, and embeddings.

#### Initialization

```crystal
memo = Memo::Service.new(
  data_dir: "/var/data/memo",  # Directory for database files
  provider: "openai",          # Embedding provider
  api_key: "sk-...",           # API key for provider
  model: nil,                  # Optional: override default model
  store_text: true,            # Optional: enable text storage (default true)
  chunking_max_tokens: 2000,   # Optional: max tokens per chunk
  attach: nil                  # Optional: external databases to ATTACH
)
```

#### Indexing

```crystal
# Index single document
memo.index(
  source_type: "article",
  source_id: 123_i64,
  text: "Long text to index...",
  pair_id: nil,      # Optional: related source
  parent_id: nil     # Optional: hierarchical parent
)

# Index with Document struct
doc = Memo::Document.new(
  source_type: "article",
  source_id: 123_i64,
  text: "Document text..."
)
memo.index(doc)

# Batch indexing (more efficient)
docs = [
  Memo::Document.new(source_type: "article", source_id: 1_i64, text: "First..."),
  Memo::Document.new(source_type: "article", source_id: 2_i64, text: "Second..."),
]
memo.index_batch(docs)
```

#### Search

```crystal
results = memo.search(
  query: "search query",
  limit: 10,
  min_score: 0.7,
  source_type: nil,    # Optional: filter by type
  source_id: nil,      # Optional: filter by ID
  pair_id: nil,        # Optional: filter by pair
  parent_id: nil,      # Optional: filter by parent
  like: nil,           # Optional: LIKE pattern(s) for text filtering
  match: nil,          # Optional: FTS5 full-text search query
  sql_where: nil,      # Optional: raw SQL WHERE clause
  include_text: false  # Optional: include text content in results
)
```

#### Text Filtering

When text storage is enabled, you can filter by text content:

```crystal
# LIKE pattern (single)
results = memo.search(query: "cats", like: "%kitten%")

# LIKE patterns (AND logic)
results = memo.search(query: "pets", like: ["%cat%", "%dog%"])

# FTS5 full-text search
results = memo.search(query: "animals", match: "cats OR dogs")
results = memo.search(query: "animals", match: "quick brown*")  # prefix
results = memo.search(query: "animals", match: '"exact phrase"')

# Include text in results
results = memo.search(query: "cats", include_text: true)
results.each { |r| puts r.text }
```

#### External Database Filtering

Use ATTACH to filter against your application's database:

```crystal
memo = Memo::Service.new(
  data_dir: "/var/data/memo",
  attach: {"app" => "/var/data/app.db"},
  provider: "openai",
  api_key: key
)

# Filter chunks by external table
results = memo.search(
  query: "project updates",
  sql_where: "c.source_id IN (SELECT id FROM app.articles WHERE status = 'published')"
)
```

#### Other Operations

```crystal
# Get statistics
stats = memo.stats
puts "Embeddings: #{stats.embeddings}, Chunks: #{stats.chunks}, Sources: #{stats.sources}"

# Delete by source
memo.delete(source_id: 123_i64)
memo.delete(source_id: 123_i64, source_type: "article")  # More specific

# Mark chunks as read
memo.mark_as_read(chunk_ids: [1_i64, 2_i64])

# Close connection
memo.close
```

### Search Results

```crystal
struct Memo::Search::Result
  getter chunk_id : Int64
  getter source_type : String
  getter source_id : Int64
  getter score : Float64
  getter pair_id : Int64?
  getter parent_id : Int64?
  getter text : String?  # When include_text: true
end
```

## Storage

Memo stores data in the specified directory:

- `embeddings.db` - Embeddings, chunks, projections (can be regenerated)
- `text.db` - Text content and FTS5 index (persistent)

Text storage can be disabled with `store_text: false` if you prefer to manage text separately.

## Providers

Currently supported:
- `openai` - OpenAI text-embedding-3-small (default), text-embedding-3-large
- `mock` - Deterministic embeddings for testing

## Architecture

See [DESIGN.md](DESIGN.md) for detailed architecture documentation.

## License

MIT
