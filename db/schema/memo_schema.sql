-- Consolidated Memo Schema
--
-- This file contains all Memo tables for deployment in a standalone database.
-- When Memo operates in its own memo.db file, these tables don't need
-- a "memo_" prefix since they're isolated from other application tables.
--
-- Alternatively, when embedded in an application's database, tables use
-- a configurable prefix (default "memo_") to avoid conflicts.

-- =============================================================================
-- AI embedding service registry
--
-- Named service configurations for embedding providers.
-- Each embedding references a service to ensure compatibility.
--
-- When searching, filter by service_id to only compare embeddings
-- from the same vector space (same format/model/dimensions).
-- =============================================================================

CREATE TABLE IF NOT EXISTS services (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,        -- User-defined service name (lookup key)
    format TEXT NOT NULL,             -- API format (e.g., "openai", "mock")
    base_url TEXT,                    -- Optional custom API endpoint
    model TEXT NOT NULL,              -- Model name (e.g., "text-embedding-3-small")
    dimensions INTEGER NOT NULL,      -- Vector dimensions (e.g., 1536)
    max_tokens INTEGER NOT NULL,      -- Model's maximum tokens per chunk
    tokens_per_byte REAL DEFAULT 0.25, -- Running estimate of tokens/byte ratio
    is_default INTEGER DEFAULT 0,     -- 1 if this is the default service
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_services_format ON services(format);
CREATE INDEX IF NOT EXISTS idx_services_default ON services(is_default);

-- Preload services

-- OpenAI models
INSERT OR IGNORE INTO services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('openai', 'openai', NULL, 'text-embedding-3-small', 1536, 8191, 1, 0);

INSERT OR IGNORE INTO services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('openai/text-embedding-3-large', 'openai', NULL, 'text-embedding-3-large', 3072, 8191, 0, 0);

INSERT OR IGNORE INTO services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('openai/text-embedding-ada-002', 'openai', NULL, 'text-embedding-ada-002', 1536, 8191, 0, 0);

-- Voyage AI models
INSERT OR IGNORE INTO services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('voyage', 'voyage', NULL, 'voyage-3', 1024, 32000, 0, 0);

INSERT OR IGNORE INTO services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('voyage/voyage-3-lite', 'voyage', NULL, 'voyage-3-lite', 512, 32000, 0, 0);

INSERT OR IGNORE INTO services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('voyage/voyage-code-3', 'voyage', NULL, 'voyage-code-3', 1024, 32000, 0, 0);

INSERT OR IGNORE INTO services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('voyage/voyage-finance-2', 'voyage', NULL, 'voyage-finance-2', 1024, 32000, 0, 0);

INSERT OR IGNORE INTO services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('voyage/voyage-law-2', 'voyage', NULL, 'voyage-law-2', 1024, 32000, 0, 0);

-- Mock service for development/testing
INSERT OR IGNORE INTO services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('mock', 'mock', NULL, 'mock-8d', 8, 100, 0, 0);

-- =============================================================================
-- Embeddings table: Content hash → vector embedding mapping
--
-- Stores the actual embedding vectors and metadata. Content is deduplicated
-- by hash - identical text produces identical embeddings and only stored once.
--
-- The hash serves as both content identifier and primary key, ensuring
-- automatic deduplication.
--
-- Each embedding references a service (provider/model) to track which AI
-- service created it. This ensures searches only compare embeddings from
-- compatible vector spaces.
-- =============================================================================

CREATE TABLE IF NOT EXISTS embeddings (
    hash BLOB NOT NULL,              -- Content hash (SHA256 of text)
    service_id INTEGER NOT NULL,     -- FK to services table
    embedding BLOB NOT NULL,         -- Vector embedding (serialized floats)
    token_count INTEGER NOT NULL,    -- Tokens in embedded text
    created_at INTEGER NOT NULL,     -- Unix timestamp (ms)

    PRIMARY KEY (hash, service_id),
    FOREIGN KEY (service_id) REFERENCES services(id)
);

CREATE INDEX IF NOT EXISTS idx_embeddings_service ON embeddings(service_id);

-- =============================================================================
-- Projection vectors: Random orthogonal vectors for fast similarity filtering
--
-- Stores k random orthogonal unit vectors per service. These are generated once
-- when a service is first registered and used to compute low-dimensional
-- projections of embeddings for fast pre-filtering during search.
--
-- Each embedding's projection onto these vectors approximates its position in
-- the full vector space, allowing quick elimination of dissimilar candidates
-- before expensive full cosine similarity computation.
--
-- Vectors are stored as BLOBs in the same format as embeddings (little-endian
-- Float32). Each vector has the same dimension as the service's embeddings.
-- =============================================================================

CREATE TABLE IF NOT EXISTS projection_vectors (
    service_id INTEGER PRIMARY KEY,  -- FK to services table (one row per service)
    vec_0 BLOB NOT NULL,             -- Random orthogonal unit vector
    vec_1 BLOB NOT NULL,
    vec_2 BLOB NOT NULL,
    vec_3 BLOB NOT NULL,
    vec_4 BLOB NOT NULL,
    vec_5 BLOB NOT NULL,
    vec_6 BLOB NOT NULL,
    vec_7 BLOB NOT NULL,
    created_at INTEGER NOT NULL,

    FOREIGN KEY (service_id) REFERENCES services(id)
);

-- =============================================================================
-- Projections: Low-dimensional projections for fast similarity filtering
--
-- Stores dot products of each embedding with the service's projection vectors.
-- During search, query projections are compared against stored projections to
-- quickly filter candidates before full cosine similarity computation.
--
-- The projection values approximate position in the embedding space. Embeddings
-- with similar projections are likely to have high cosine similarity.
-- =============================================================================

CREATE TABLE IF NOT EXISTS projections (
    hash BLOB NOT NULL,              -- FK to embeddings(hash, service_id)
    service_id INTEGER NOT NULL,     -- FK to services table
    proj_0 REAL NOT NULL,            -- Dot product with vec_0
    proj_1 REAL NOT NULL,            -- Dot product with vec_1
    proj_2 REAL NOT NULL,            -- Dot product with vec_2
    proj_3 REAL NOT NULL,            -- Dot product with vec_3
    proj_4 REAL NOT NULL,            -- Dot product with vec_4
    proj_5 REAL NOT NULL,            -- Dot product with vec_5
    proj_6 REAL NOT NULL,            -- Dot product with vec_6
    proj_7 REAL NOT NULL,            -- Dot product with vec_7

    PRIMARY KEY (hash, service_id),
    FOREIGN KEY (hash, service_id) REFERENCES embeddings(hash, service_id)
);

-- =============================================================================
-- Sources table: Identity mapping for flexible external IDs
--
-- Maps external source identifiers (integer or string) to internal integer IDs.
-- This enables:
--   - Integer IDs: Time-based, sortable (e.g., Unix timestamps)
--   - String IDs: UUIDs and other text identifiers
--   - No external ID: Memo-managed sources (e.g., file indexer)
--
-- Each source is identified by (source_type, external_int) OR (source_type, external_text),
-- or by internal id only when no external ID is provided.
-- =============================================================================

CREATE TABLE IF NOT EXISTS sources (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_type TEXT NOT NULL,       -- Application-defined type
    external_int INTEGER,            -- Integer external ID (sortable, optional)
    external_text TEXT,              -- String external ID (UUID, etc., optional)
    external_blob BLOB,              -- Binary external ID (raw hash, binary UUID, optional)
    created_at INTEGER NOT NULL,

    -- External IDs are optional, but if provided, must be unique per source_type
    UNIQUE(source_type, external_int),
    UNIQUE(source_type, external_text),
    UNIQUE(source_type, external_blob)
);

CREATE INDEX IF NOT EXISTS idx_sources_type_int ON sources(source_type, external_int)
    WHERE external_int IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sources_type_text ON sources(source_type, external_text)
    WHERE external_text IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sources_type_blob ON sources(source_type, external_blob)
    WHERE external_blob IS NOT NULL;

-- =============================================================================
-- Chunks table: Links content hashes to sources
--
-- Maps embeddings back to their original sources. A single embedding (hash)
-- can be referenced by multiple chunks if the same content appears in different
-- locations or contexts.
--
-- Source identification:
--   - source_id: FK to sources.id (internal identifier)
--   - source_type: Denormalized for fast filtering (matches sources.source_type)
--
-- Relationships (optional):
--   - pair_id: Related source (FK to sources.id)
--   - parent_id: Hierarchical parent (FK to sources.id)
--
-- Usage tracking:
--   - match_count: How many times this chunk appeared in search results
--   - read_count: How many times this chunk was actually included in context
-- =============================================================================

CREATE TABLE IF NOT EXISTS chunks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    hash BLOB NOT NULL,              -- Content hash (references embeddings via join)

    -- Source identification (FK to sources table)
    source_id INTEGER NOT NULL REFERENCES sources(id),
    source_type TEXT NOT NULL,       -- Denormalized for fast filtering

    -- Relationships (FK to sources.id, nullable)
    pair_id INTEGER REFERENCES sources(id),
    parent_id INTEGER REFERENCES sources(id),

    -- Chunk location within source
    offset INTEGER,                  -- Character position in source
    size INTEGER NOT NULL,           -- Chunk size in characters

    -- Usage metrics
    match_count INTEGER NOT NULL DEFAULT 0,
    read_count INTEGER NOT NULL DEFAULT 0,

    created_at INTEGER NOT NULL,

    -- Note: hash is a soft reference to embeddings. No FK constraint because
    -- embeddings has composite PK (hash, service_id). Integrity is enforced
    -- at query time by joining on hash with service_id filter.
    UNIQUE(source_id, offset)
);

CREATE INDEX IF NOT EXISTS idx_chunks_hash ON chunks(hash);
CREATE INDEX IF NOT EXISTS idx_chunks_source ON chunks(source_type, source_id);
CREATE INDEX IF NOT EXISTS idx_chunks_pair ON chunks(pair_id) WHERE pair_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_chunks_parent ON chunks(parent_id) WHERE parent_id IS NOT NULL;

-- =============================================================================
-- Embedding queue: Tracks pending embedding work
--
-- Allows batch processing of embeddings. Applications enqueue sources that need
-- embedding, and a background processor can work through the queue.
--
-- Status codes:
--   -1 = pending (not yet processed)
--    0 = success (embedded successfully)
--   >0 = error codes (HTTP errors like 429, 503, or custom app errors)
--
-- The queue supports retry logic via the attempts counter, allowing applications
-- to implement exponential backoff or retry limits.
-- =============================================================================

CREATE TABLE IF NOT EXISTS embed_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_id INTEGER NOT NULL REFERENCES sources(id),  -- FK to sources table
    text TEXT,                       -- Pre-extracted text (optional, for efficiency)
    status INTEGER NOT NULL DEFAULT -1,  -- -1=pending, 0=success, >0=error
    error_message TEXT,              -- Error details if status > 0
    attempts INTEGER NOT NULL DEFAULT 0, -- Retry counter
    created_at INTEGER NOT NULL,     -- Unix timestamp (ms) when enqueued
    processed_at INTEGER,            -- Unix timestamp (ms) when processed

    UNIQUE(source_id)
);

-- Index for finding pending items
CREATE INDEX IF NOT EXISTS idx_queue_pending ON embed_queue(status) WHERE status = -1;

-- Index for finding failed items to retry
CREATE INDEX IF NOT EXISTS idx_queue_retries ON embed_queue(status, attempts) WHERE status > 0;

-- =============================================================================
-- Text storage: Original document content
--
-- Stores the original un-chunked text for each source. Chunk text can be
-- extracted using offset/size from the chunks table via SUBSTR.
--
-- This enables:
-- - Text retrieval in search results without external lookups
-- - Full-text search via FTS5
-- - Reindexing without requiring the original source
-- =============================================================================

CREATE TABLE IF NOT EXISTS texts (
    source_id INTEGER PRIMARY KEY REFERENCES sources(id),  -- FK to sources table
    content TEXT NOT NULL,
    content_hash BLOB,  -- SHA256 hash for change detection
    created_at INTEGER NOT NULL
);

-- FTS5 virtual table for full-text search on source content
-- Note: source_id here is the internal ID (FK to sources)
CREATE VIRTUAL TABLE IF NOT EXISTS texts_fts
USING fts5(source_id UNINDEXED, content);

-- =============================================================================
-- Vocabulary table: Word-level embeddings for concept similarity
--
-- Stores unique words extracted from indexed content with their embeddings.
-- Enables word-level semantic search via `memo like "word"`.
--
-- Words are extracted during `build-vocab` command:
-- 1. Query all text from texts table
-- 2. Tokenize and normalize
-- 3. Filter stopwords, short/long words, numbers
-- 4. Batch embed unique terms
-- 5. Store in vocab table
-- =============================================================================

CREATE TABLE IF NOT EXISTS vocab (
    word TEXT NOT NULL,              -- Normalized word (lowercase, stripped)
    service_id INTEGER NOT NULL,     -- FK to services table
    embedding BLOB NOT NULL,         -- Vector embedding (Float32, same as embeddings)
    frequency INTEGER DEFAULT 1,     -- How often word appears in corpus
    created_at INTEGER NOT NULL,     -- Unix timestamp (ms)

    PRIMARY KEY (word, service_id),
    FOREIGN KEY (service_id) REFERENCES services(id)
);

CREATE INDEX IF NOT EXISTS idx_vocab_service ON vocab(service_id);

-- =============================================================================
-- Files table: File metadata for memo-managed file indexing
--
-- Tracks file paths, content hashes, and modification times for files indexed
-- via the CLI `index-files` command. Enables:
--   - Re-indexing by path (find existing source)
--   - Incremental updates (skip unchanged files via mtime)
--   - Cross-system correlation via content_hash
--
-- For memo-managed sources (no external_id), this table provides the lookup
-- mechanism. External systems can query by content_hash to correlate.
-- =============================================================================

CREATE TABLE IF NOT EXISTS files (
    source_id INTEGER PRIMARY KEY REFERENCES sources(id),
    path TEXT NOT NULL,              -- Relative file path
    content_hash BLOB NOT NULL,      -- SHA256 of file content
    mtime INTEGER NOT NULL,          -- File modification time (Unix ms)
    size INTEGER NOT NULL,           -- File size in bytes
    created_at INTEGER NOT NULL,

    UNIQUE(path)
);

CREATE INDEX IF NOT EXISTS idx_files_hash ON files(content_hash);
