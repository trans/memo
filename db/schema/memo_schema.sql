-- Consolidated Memo Schema
--
-- This file contains all Memo tables for deployment in a standalone database.
-- When Memo operates in its own embeddings.db file, these tables don't need
-- a "memo_" prefix since they're isolated from other application tables.

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
    is_default INTEGER DEFAULT 0,     -- 1 if this is the default service
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_services_format ON services(format);
CREATE INDEX IF NOT EXISTS idx_services_default ON services(is_default);

-- Preload default mock service for development/testing
INSERT OR IGNORE INTO services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('mock', 'mock', NULL, 'mock-8d', 8, 100, 1, 0);

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
    hash BLOB PRIMARY KEY,           -- Content hash (SHA256 of text)
    embedding BLOB NOT NULL,         -- Vector embedding (serialized floats)
    token_count INTEGER NOT NULL,    -- Tokens in embedded text
    service_id INTEGER NOT NULL,     -- FK to services table
    created_at INTEGER NOT NULL,     -- Unix timestamp (ms)

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
    hash BLOB PRIMARY KEY,           -- FK to embeddings(hash)
    proj_0 REAL NOT NULL,            -- Dot product with vec_0
    proj_1 REAL NOT NULL,            -- Dot product with vec_1
    proj_2 REAL NOT NULL,            -- Dot product with vec_2
    proj_3 REAL NOT NULL,            -- Dot product with vec_3
    proj_4 REAL NOT NULL,            -- Dot product with vec_4
    proj_5 REAL NOT NULL,            -- Dot product with vec_5
    proj_6 REAL NOT NULL,            -- Dot product with vec_6
    proj_7 REAL NOT NULL,            -- Dot product with vec_7

    FOREIGN KEY (hash) REFERENCES embeddings(hash)
);

-- =============================================================================
-- Chunks table: Links content hashes to external sources
--
-- Maps embeddings back to their original sources. A single embedding (hash)
-- can be referenced by multiple chunks if the same content appears in different
-- locations or contexts.
--
-- Source identification:
--   - source_type: Application-defined type (e.g., "event", "document", "artifact")
--   - source_id: Integer ID in external system
--
-- Relationships (optional):
--   - pair_id: Related source (e.g., question paired with answer)
--   - parent_id: Hierarchical parent (e.g., agent execution context)
--
-- Usage tracking:
--   - match_count: How many times this chunk appeared in search results
--   - read_count: How many times this chunk was actually included in context
-- =============================================================================

CREATE TABLE IF NOT EXISTS chunks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    hash BLOB NOT NULL,              -- FK to embeddings(hash)

    -- Source identification
    source_type TEXT NOT NULL,       -- Application-defined type
    source_id INTEGER NOT NULL,      -- External ID (integer)

    -- Relationships (nullable - not all sources are paired/nested)
    pair_id INTEGER,                 -- Related source (e.g., question for answer)
    parent_id INTEGER,               -- Hierarchical parent

    -- Chunk location within source
    offset INTEGER,                  -- Character position in source
    size INTEGER NOT NULL,           -- Chunk size in characters

    -- Usage metrics
    match_count INTEGER NOT NULL DEFAULT 0,
    read_count INTEGER NOT NULL DEFAULT 0,

    created_at INTEGER NOT NULL,

    FOREIGN KEY (hash) REFERENCES embeddings(hash),
    UNIQUE(source_type, source_id, offset)
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
    source_type TEXT NOT NULL,       -- What kind of thing to embed
    source_id INTEGER NOT NULL,      -- ID of thing to embed
    text TEXT,                       -- Pre-extracted text (optional, for efficiency)
    status INTEGER NOT NULL DEFAULT -1,  -- -1=pending, 0=success, >0=error
    error_message TEXT,              -- Error details if status > 0
    attempts INTEGER NOT NULL DEFAULT 0, -- Retry counter
    created_at INTEGER NOT NULL,     -- Unix timestamp (ms) when enqueued
    processed_at INTEGER,            -- Unix timestamp (ms) when processed

    UNIQUE(source_type, source_id)
);

-- Index for finding pending items
CREATE INDEX IF NOT EXISTS idx_queue_pending ON embed_queue(status) WHERE status = -1;

-- Index for finding failed items to retry
CREATE INDEX IF NOT EXISTS idx_queue_retries ON embed_queue(status, attempts) WHERE status > 0;
