-- Text storage: Original document content
--
-- Stores the original un-chunked text for each source. Chunk text can be
-- extracted using offset/size from the chunks table via SUBSTR.
--
-- This enables:
-- - Text retrieval in search results without external lookups
-- - Full-text search via FTS5
-- - Reindexing without requiring the original source

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
