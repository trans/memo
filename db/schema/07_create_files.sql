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
