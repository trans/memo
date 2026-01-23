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
