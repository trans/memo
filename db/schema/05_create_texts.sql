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
    source_type TEXT NOT NULL,
    source_id INTEGER NOT NULL,
    content TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (source_type, source_id)
);

-- FTS5 virtual table for full-text search on source content
CREATE VIRTUAL TABLE IF NOT EXISTS texts_fts
USING fts5(source_type, source_id UNINDEXED, content);
