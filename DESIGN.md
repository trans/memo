# Memo Library Design

## Overview

Memo is a semantic search library for Crystal that provides:
- Text chunking with configurable parameters
- Vector embedding storage with deduplication
- Similarity search with projection-based pre-filtering
- Text storage with LIKE and FTS5 full-text search

## Core Concepts

**Document → Chunks → Embeddings → Search Results**

1. **Chunking**: Break large text into optimal-sized pieces
2. **Embedding**: Generate vector representations of chunks
3. **Storage**: Store embeddings and optionally text content
4. **Search**: Find similar chunks via vector similarity with text filtering
5. **Projection filtering**: Fast candidate pre-filtering using random projections

## Storage Architecture

Memo stores all data in a single SQLite file at the provided `db_path`:

```
/var/data/memo.db    # Services, embeddings, chunks, projections, texts, queue
```

The database contains all tables needed for semantic search and text storage.

## Database Schema

### `services` - Provider Registry

Tracks which provider/model created embeddings to ensure compatible vector spaces.

```sql
CREATE TABLE services (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    provider TEXT NOT NULL,           -- "openai", "mock", etc.
    model TEXT NOT NULL,              -- "text-embedding-3-small"
    version TEXT,                     -- Optional model version
    dimensions INTEGER NOT NULL,      -- 1536, 3072, etc.
    max_tokens INTEGER NOT NULL,      -- Model's token limit
    created_at INTEGER NOT NULL,
    UNIQUE(provider, model, version, dimensions)
);
```

### `embeddings` - Vector Storage

Stores embedding vectors, deduplicated by content hash.

```sql
CREATE TABLE embeddings (
    hash BLOB PRIMARY KEY,           -- SHA256 of text
    embedding BLOB NOT NULL,         -- Float32 array
    token_count INTEGER NOT NULL,
    service_id INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (service_id) REFERENCES services(id)
);
```

### `chunks` - Source References

Links embeddings back to application sources.

```sql
CREATE TABLE chunks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    hash BLOB NOT NULL,              -- FK to embeddings
    source_type TEXT NOT NULL,       -- "article", "note", etc.
    source_id INTEGER NOT NULL,      -- External ID
    pair_id INTEGER,                 -- Related source
    parent_id INTEGER,               -- Hierarchical parent
    offset INTEGER,                  -- Char position in source
    size INTEGER NOT NULL,           -- Chunk size in chars
    match_count INTEGER DEFAULT 0,   -- Times in search results
    read_count INTEGER DEFAULT 0,    -- Times marked as read
    created_at INTEGER NOT NULL,
    FOREIGN KEY (hash) REFERENCES embeddings(hash)
);
```

### `projections` - Fast Filtering

Stores random projection values for pre-filtering candidates.

```sql
CREATE TABLE projections (
    hash BLOB PRIMARY KEY,
    p0 REAL, p1 REAL, p2 REAL, p3 REAL,
    p4 REAL, p5 REAL, p6 REAL, p7 REAL,
    FOREIGN KEY (hash) REFERENCES embeddings(hash)
);
```

### `projection_vectors` - Projection Configuration

Stores the random vectors used for projection (per service).

```sql
CREATE TABLE projection_vectors (
    service_id INTEGER PRIMARY KEY,
    vectors BLOB NOT NULL,           -- Serialized projection vectors
    FOREIGN KEY (service_id) REFERENCES services(id)
);
```

### `texts` - Text Content

Stores source text content for retrieval and filtering.

```sql
CREATE TABLE texts (
    source_type TEXT NOT NULL,
    source_id INTEGER NOT NULL,
    content TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (source_type, source_id)
);
```

### `texts_fts` - Full-Text Search Index

FTS5 virtual table for full-text search.

```sql
CREATE VIRTUAL TABLE texts_fts USING fts5(
    source_type,
    source_id UNINDEXED,
    content
);
```

## API Design

### Initialization

```crystal
# Standard initialization with text storage
memo = Memo::Service.new(
  db_path: "/var/data/memo.db",
  format: "openai",
  api_key: ENV["OPENAI_API_KEY"]
)

# With explicit model and dimensions
memo = Memo::Service.new(
  db_path: "/var/data/memo.db",
  format: "openai",
  api_key: api_key,
  model: "text-embedding-3-large",  # Default: text-embedding-3-small
  dimensions: 3072                   # Auto-detected from model if not specified
)

# Without text storage (manage text separately)
memo = Memo::Service.new(
  db_path: "/var/data/memo.db",
  format: "openai",
  api_key: api_key,
  store_text: false
)

# With queue configuration
memo = Memo::Service.new(
  db_path: "/var/data/memo.db",
  format: "openai",
  api_key: api_key,
  batch_size: 100,    # Max texts per embedding API call (default: 100)
  max_retries: 3      # Queue retry limit (default: 3)
)
```

**Initialization parameters:**
- `db_path`: Path to database file (required)
- `format`: "openai", "voyage", or "mock" (required)
- `api_key`: Provider API key (required for openai/voyage)
- `model`: Embedding model (default: text-embedding-3-small)
- `dimensions`: Vector dimensions (auto-detected from model)
- `max_tokens`: Provider token limit (auto-detected from model)
- `chunking_max_tokens`: Max tokens per chunk (default: 2000)
- `store_text`: Enable text storage (default: true)
- `batch_size`: Max texts per embedding API call (default: 100)
- `max_retries`: Queue retry limit before marking failed (default: 3)

### Indexing

All indexing operations use the embed queue internally, providing automatic retry
support and error tracking.

```crystal
# Single document (enqueues and processes immediately)
memo.index(
  source_type: "article",
  source_id: 123_i64,
  text: "Document text...",
  pair_id: nil,      # Optional
  parent_id: nil     # Optional
)

# Using Document struct
doc = Memo::Document.new(
  source_type: "article",
  source_id: 123_i64,
  text: "Document text..."
)
memo.index(doc)

# Batch indexing (enqueues all, then processes)
docs = [
  Memo::Document.new(source_type: "article", source_id: 1_i64, text: "First..."),
  Memo::Document.new(source_type: "article", source_id: 2_i64, text: "Second..."),
]
memo.index_batch(docs)
```

**Indexing process:**
1. Enqueue document in embed_queue table
2. Chunk text into optimal-sized pieces
3. Generate embeddings via provider API (with retry on failure)
4. Compute projection values for fast filtering
5. Store embeddings (deduplicated by content hash)
6. Create chunk references linking to source
7. Store text content in texts table (if enabled)
8. Mark queue item as completed

### Search

```crystal
# Basic search
results = memo.search(query: "search terms", limit: 10)

# With filters
results = memo.search(
  query: "search terms",
  limit: 10,
  min_score: 0.7,
  source_type: "article",
  parent_id: 42_i64
)

# With text filtering (requires text storage)
results = memo.search(query: "cats", like: "%kitten%")
results = memo.search(query: "pets", like: ["%cat%", "%dog%"])  # AND logic
results = memo.search(query: "animals", match: "cats OR dogs")  # FTS5

# Include text in results
results = memo.search(query: "cats", include_text: true)
```

**Search process:**
1. Generate query embedding
2. Compute query projections
3. Pre-filter candidates using projection distance
4. Apply text filters (LIKE, FTS5) if specified
5. Apply custom SQL filter if specified
6. Compute cosine similarity for candidates
7. Return results ranked by similarity

### Search Results

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
  getter text : String?      # When include_text: true
end
```

### Other Operations

```crystal
# Statistics
stats = memo.stats
# => Stats(embeddings: 1000, chunks: 1200, sources: 50)

# Delete by source
memo.delete(source_id: 123_i64)
memo.delete(source_id: 123_i64, source_type: "article")

# Mark as read (increments read_count)
memo.mark_as_read(chunk_ids: [1_i64, 2_i64])

# Close connection
memo.close
```

### Queue Operations

While `index()` and `index_batch()` use the queue internally and process immediately,
you can also use the queue directly for deferred/background processing:

```crystal
# Enqueue documents for later processing
memo.enqueue(source_type: "article", source_id: 123_i64, text: "Document text...")
memo.enqueue(doc)  # Document struct

# Batch enqueue (no embedding yet)
memo.enqueue_batch(docs)

# Process queue later (blocks until complete)
processed = memo.process_queue
# => 42

# Or process asynchronously (returns immediately)
memo.process_queue_async

# Check queue status
stats = memo.queue_stats
# => QueueStats(pending: 10, failed: 2)

# Clear completed items
memo.clear_completed_queue

# Clear all items
memo.clear_queue

# Re-index all content of a source type
# (requires text storage enabled)
queued = memo.reindex(source_type: "article")
memo.process_queue  # Actually re-embed

# Re-index with block (when text storage disabled)
# Block receives source_id and returns text
memo.reindex("article") do |source_id|
  app.get_article_text(source_id)
end
memo.process_queue
```

**Queue behavior:**
- Items are processed in batches using `batch_size` (default: 100)
- Failed items retry up to `max_retries` times (default: 3)
- After max retries, items are marked as permanently failed (status > 0)
- `reindex` without block requires text storage; with block works regardless

## Projection Filtering

Memo uses random projection for fast candidate pre-filtering:

1. **Projection vectors**: 8 random orthogonal vectors generated per service
2. **Projection values**: Each embedding is projected onto these vectors (8 scalar values)
3. **Distance estimation**: Manhattan distance between query and stored projections approximates cosine distance
4. **Pre-filtering**: Candidates outside a distance threshold are skipped before expensive cosine computation

This reduces the number of full cosine similarity calculations needed, improving search performance on large datasets.

## Text Filtering

When text storage is enabled, two text filtering methods are available:

### LIKE Patterns

Simple pattern matching with `%` wildcards:

```crystal
# Single pattern
memo.search(query: "cats", like: "%kitten%")

# Multiple patterns (AND logic)
memo.search(query: "pets", like: ["%cat%", "%dog%"])
```

### FTS5 Full-Text Search

SQLite's FTS5 provides powerful full-text search:

```crystal
memo.search(query: "animals", match: "cats OR dogs")     # Boolean
memo.search(query: "animals", match: "quick brown*")    # Prefix
memo.search(query: "animals", match: '"exact phrase"')  # Phrase
memo.search(query: "animals", match: "cats NOT dogs")   # Negation
```

## Design Decisions

1. **Single-file storage**: One SQLite database for all data
2. **Projection pre-filtering**: Fast candidate reduction before cosine similarity
3. **Content-hash deduplication**: Same text stored once regardless of source
4. **Service isolation**: Embeddings from different models never mixed
5. **Optional text storage**: Disable with `store_text: false` if managing text separately
6. **FTS5 integration**: Full-text search alongside semantic search

## Providers

Currently supported:
- `openai` - text-embedding-3-small (1536d), text-embedding-3-large (3072d)
- `voyage` - voyage-3 (1024d), voyage-3-lite (512d), voyage-code-3 (1024d)
- `mock` - Deterministic embeddings for testing (8d)

## License

MIT
