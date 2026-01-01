# Memo Library Design

## Overview

Memo is a semantic search library for Crystal that provides:
- Text chunking with configurable parameters
- Vector embedding storage with deduplication and service tracking
- Similarity search with filtering
- Reciprocal Rank Fusion (RRF) for hybrid search
- Background embedding queue processing

## Core Concepts

**Document → Chunks → Embeddings → Search Results**

1. **Chunking**: Break large text into optimal-sized pieces
2. **Embedding**: Generate vector representations of chunks
3. **Storage**: Store embeddings with source references and service metadata
4. **Search**: Find similar chunks via vector similarity (same service only)
5. **Fusion**: Combine multiple search strategies (RRF)

## Database Schema

Memo uses **4 tables** (all prefixed with `memo_` by default):

### 1. `memo_services` - AI Provider Registry

Tracks which provider/model created embeddings to ensure compatible vector spaces.

```sql
CREATE TABLE memo_services (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    provider TEXT NOT NULL,           -- "openai", "cohere", etc.
    model TEXT NOT NULL,              -- "text-embedding-3-small"
    version TEXT,                     -- Optional model version
    dimensions INTEGER NOT NULL,      -- 1536, 768, etc.
    max_tokens INTEGER NOT NULL,      -- Model's token limit
    created_at INTEGER NOT NULL,
    UNIQUE(provider, model, version, dimensions)
);
```

**Why?** Different models create incompatible vector spaces. Searching 1536-dim OpenAI embeddings against 768-dim Cohere embeddings is meaningless. The service table ensures we only compare compatible embeddings.

### 2. `memo_embeddings` - Vector Storage

Stores actual embedding vectors, deduplicated by content hash.

```sql
CREATE TABLE memo_embeddings (
    hash BLOB PRIMARY KEY,           -- SHA256 of text (deduplication)
    embedding BLOB NOT NULL,         -- Float32 array (space efficient)
    token_count INTEGER NOT NULL,
    service_id INTEGER NOT NULL,     -- FK to memo_services
    created_at INTEGER NOT NULL,
    FOREIGN KEY (service_id) REFERENCES memo_services(id)
);
```

**Deduplication**: Same text = same hash = stored once, even if indexed multiple times.

**Service tracking**: Each embedding knows which provider/model created it via `service_id`.

### 3. `memo_chunks` - Source References

Links embeddings back to application sources with usage metrics.

```sql
CREATE TABLE memo_chunks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    hash BLOB NOT NULL,              -- FK to memo_embeddings
    source_type TEXT NOT NULL,       -- "event", "document", etc.
    source_id INTEGER NOT NULL,      -- External ID
    pair_id INTEGER,                 -- Related source
    parent_id INTEGER,               -- Hierarchical parent
    offset INTEGER,                  -- Char position in source
    size INTEGER NOT NULL,           -- Chunk size in chars
    match_count INTEGER DEFAULT 0,   -- Times in search results
    read_count INTEGER DEFAULT 0,    -- Times actually used
    created_at INTEGER NOT NULL,
    FOREIGN KEY (hash) REFERENCES memo_embeddings(hash)
);
```

**Usage tracking**: `match_count` and `read_count` help identify relevant vs noise.

### 4. `memo_embed_queue` - Background Processing

Tracks pending embedding work (not yet implemented).

```sql
CREATE TABLE memo_embed_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_type TEXT NOT NULL,
    source_id INTEGER NOT NULL,
    text TEXT,
    status INTEGER DEFAULT -1,       -- -1=pending, 0=success, >0=error
    error_message TEXT,
    attempts INTEGER DEFAULT 0,
    created_at INTEGER NOT NULL,
    processed_at INTEGER,
    UNIQUE(source_type, source_id)
);
```

## API Design

### 1. Quick Start

```crystal
require "memo"

# Initialize database
db = DB.open("sqlite3://app.db")
Memo::Database.load_schema(db)

# Create service (handles embeddings internally)
memo = Memo::Service.new(
  db: db,
  provider: "openai",
  api_key: ENV["OPENAI_API_KEY"],
  model: "text-embedding-3-small",  # Optional (defaults to provider default)
  dimensions: 1536,                  # Optional (auto-detected from model)
  max_tokens: 8191,                  # Optional (auto-detected from model)
  chunking_max_tokens: 2000          # Optional (default 2000)
)

# Index a document
memo.index(
  source_type: "document",
  source_id: 42,
  text: "Your document text..."
)

# Search
results = memo.search(query: "search query", limit: 10)
```

### 2. Service Configuration

```crystal
# Required parameters
memo = Memo::Service.new(
  db: db,                # Database connection
  provider: "openai",    # Provider name ("openai" or "mock")
  api_key: api_key       # Provider API key (not needed for mock)
)

# Optional parameters with smart defaults
memo = Memo::Service.new(
  db: db,
  provider: "openai",
  api_key: api_key,
  model: "text-embedding-3-small",  # Provider default if not specified
  dimensions: 1536,                  # Auto-detected from model
  max_tokens: 8191,                  # Auto-detected from model
  chunking_max_tokens: 2000          # Your preferred chunk size (default 2000)
)
```

**Key distinction:**
- `max_tokens` (8191) = Provider's hard limit
- `chunking_max_tokens` (2000) = Your preference for semantic coherence
- Validation ensures `chunking_max_tokens <= max_tokens`

### 3. Indexing Documents

```crystal
# Create service instance
memo = Memo::Service.new(
  db: db,
  provider: "openai",
  api_key: api_key
)

# Index a document - returns number of chunks stored
count = memo.index(
  source_type: "document",
  source_id: 42,
  text: "Your document text here...",
  pair_id: nil,          # Optional: related source
  parent_id: nil         # Optional: hierarchical parent
)

puts "Indexed #{count} chunks"
```

**What happens internally:**
1. Validates `chunking_max_tokens <= max_tokens` (at service initialization)
2. Registers service (or gets existing): `"openai:text-embedding-3-small:1536"` → `service_id`
3. Chunks text using chunking config
4. Generates embeddings via provider (OpenAI API)
5. Stores embeddings with `service_id` (deduplication by hash)
6. Creates chunk references linking to source
7. Returns count of chunks successfully stored

### 4. Searching

```crystal
# Service handles query embedding automatically
results = memo.search(
  query: "authentication methods",
  limit: 10,
  min_score: 0.7,
  source_type: "document",  # Optional filter
  parent_id: 123            # Optional filter
)

# Results contain references
results.each do |result|
  puts "Score: #{result.score}"
  puts "Source: #{result.source_type}:#{result.source_id}"
  puts "Chunk: #{result.chunk_id}"
  puts "Match count: #{result.match_count}"
end

# Track that results were read (increments read_count)
chunk_ids = results.map(&.chunk_id)
memo.mark_as_read(chunk_ids)
```

**What happens internally:**
1. Service generates query embedding using its provider
2. Searches against embeddings from the same service_id only
3. Filters results by source_type/parent_id if specified
4. Returns results ranked by cosine similarity

### 5. Search Result Structure

```crystal
struct Memo::Search::Result
  getter chunk_id : Int64
  getter hash : Bytes
  getter source_type : String
  getter source_id : Int64
  getter pair_id : Int64?
  getter parent_id : Int64?
  getter offset : Int32?
  getter size : Int32
  getter match_count : Int32
  getter read_count : Int32
  getter score : Float64
  getter text : String?  # Only populated if include_text: true
end
```

### 6. Hybrid Search (RRF)

```crystal
# Memo provides RRF utility for combining search strategies
# (Apps implement other search strategies - e.g., keyword search)

# Get semantic results from memo
semantic_results = memo.search(query: "auth", limit: 50)

# Get keyword results from your app's search
keyword_results = MyApp.keyword_search(patterns, limit: 50)

# Convert to RRF format and merge
semantic_items = semantic_results.map { |r| Memo::RRF::ResultItem.new(r.chunk_id, r.score) }
keyword_items = keyword_results.map { |r| Memo::RRF::ResultItem.new(r.id, r.relevance) }

merged = Memo::RRF.merge([semantic_items, keyword_items])

# Top results combine both strategies
top_10 = merged.first(10)
```

### 7. Advanced: Internal Modules

For advanced use cases, internal modules (Storage, Search, Chunking, RRF) remain accessible, but the Service API is the recommended entry point.

```crystal
# Direct storage operations (for advanced use)
hash = Memo::Storage.compute_hash(text)
service_id = memo.service_id  # Access service's registered ID

# Direct chunking (Service handles this internally)
chunks = Memo::Chunking.chunk_text(text, memo.chunking_config)

# Direct search (Service.search wraps this)
results = Memo::Search.semantic(db, embedding, service_id, limit: 10)
```

## Design Principles

1. **Simple service API** - Configure once, use everywhere
2. **Provider encapsulation** - Built-in providers (OpenAI, Mock), extensible for more
3. **Flexible filtering** - Filter by source_type, parent_id, pair_id, etc.
4. **Usage tracking** - Built-in match_count and read_count
5. **Deduplication** - Same content only embedded once (via hash)
6. **Service isolation** - Embeddings from different models never mixed
7. **Crystal-native** - Clean structs, no magic, type-safe

## Example: Full Workflow

```crystal
require "memo"

# Setup
db = DB.open("sqlite3://memo.db")
Memo::Database.load_schema(db)

# Create service
memo = Memo::Service.new(
  db: db,
  provider: "openai",
  api_key: ENV["OPENAI_API_KEY"]
)

# Index documents
memo.index(source_type: "doc", source_id: 1, text: "Authentication guide...")
memo.index(source_type: "doc", source_id: 2, text: "Authorization patterns...")

# Search
results = memo.search(query: "how to authenticate users", limit: 5)

# Use results
results.each do |r|
  puts "Found in #{r.source_type}:#{r.source_id} (score: #{r.score})"
end

# Mark as read
memo.mark_as_read(results.map(&.chunk_id))
```

## Design Decisions ✓

1. **Service class architecture**: Apps configure once, then use simple methods
   - Encapsulates provider, config, and service_id tracking
   - No manual embedding generation or service registration
   - Clean dependency injection for testing

2. **Internal providers**: Built-in OpenAI and Mock implementations
   - Apps don't implement provider interface
   - Configure by name: `provider: "openai"`
   - Extensible for future providers (Cohere, etc.)

3. **Service tracking**: Each embedding references a service (provider/model/dimensions)
   - Prevents mixing incompatible vector spaces
   - Enables model migration without breaking existing embeddings
   - Stored once in `memo_services` table, referenced by ID

4. **Two max_tokens**:
   - `max_tokens` (8191) - Provider's hard limit
   - `chunking_max_tokens` (2000) - Your preference for semantic coherence
   - Validated at Service initialization: chunking max must be <= provider max

5. **Auto-embedding in search**: `Service.search()` generates query embedding automatically
   - No manual `embed_text()` calls needed
   - Service ensures same provider is used for query and stored embeddings

6. **Search results**: Return references by default (app retrieves text from source)

7. **Metadata**: No metadata column - apps maintain their own mapping tables

8. **Similarity**: Cosine similarity (standard for embeddings)

9. **Deduplication**: Content hash (SHA256) as embedding PK

10. **Storage efficiency**: Float32 serialization (50% smaller than Float64)

## Model Migration Scenario

When switching embedding models (e.g., OpenAI small → large):

```crystal
# Old service (existing)
old_memo = Memo::Service.new(
  db: db,
  provider: "openai",
  api_key: api_key,
  model: "text-embedding-3-small",
  dimensions: 1536
)
old_service_id = old_memo.service_id

# New service (different model)
new_memo = Memo::Service.new(
  db: db,
  provider: "openai",
  api_key: api_key,
  model: "text-embedding-3-large",
  dimensions: 3072  # Different dimensions!
)

# Re-index documents with new service
new_memo.index(source_type: "doc", source_id: 1, text: doc_text)

# Search uses new service only (automatic)
results = new_memo.search(query: "authentication")

# Eventually clean up old embeddings
db.exec("DELETE FROM memo_embeddings WHERE service_id = ?", old_service_id)
db.exec("DELETE FROM memo_services WHERE id = ?", old_service_id)
```

**Key points:**
- Both models coexist during migration (separate Service instances)
- Each Service only searches its own embeddings (never mix vector spaces)
- Old embeddings remain queryable until cleanup
