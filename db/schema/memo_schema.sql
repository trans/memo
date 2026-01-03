-- Consolidated Memo Schema
--
-- This file contains all Memo tables for deployment in a standalone database.
-- When Memo operates in its own embeddings.db file, these tables don't need
-- a "memo_" prefix since they're isolated from other application tables.

-- =============================================================================
-- AI embedding service registry
--
-- Tracks which provider/model/version created embeddings.
-- Each embedding references a service to ensure compatibility.
--
-- When searching, filter by service_id to only compare embeddings
-- from the same vector space (same provider/model/dimensions).
-- =============================================================================

CREATE TABLE IF NOT EXISTS services (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    provider TEXT NOT NULL,           -- Provider name (e.g., "openai", "cohere")
    model TEXT NOT NULL,              -- Model name (e.g., "text-embedding-3-small")
    version TEXT,                     -- Optional model version
    dimensions INTEGER NOT NULL,      -- Vector dimensions (e.g., 1536)
    max_tokens INTEGER NOT NULL,      -- Model's maximum tokens per chunk
    created_at INTEGER NOT NULL,

    UNIQUE(provider, model, version, dimensions)  -- Prevent duplicate registrations
);

CREATE INDEX IF NOT EXISTS idx_services_lookup ON services(provider, model, version);

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
