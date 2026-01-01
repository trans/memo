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
