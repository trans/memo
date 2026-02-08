-- Embeddings registry: Content hash deduplication tracking
--
-- Tracks which content has been embedded for each service. Actual vectors
-- are stored in USearch HNSW index files (one per service).
--
-- Content is deduplicated by hash - identical text only needs one embedding.
-- The SQLite rowid serves as the USearch key for vector lookup.

CREATE TABLE IF NOT EXISTS embeddings (
    hash BLOB NOT NULL,              -- Content hash (SHA256 of text)
    service_id INTEGER NOT NULL,     -- FK to services table
    token_count INTEGER NOT NULL,    -- Tokens in embedded text
    created_at INTEGER NOT NULL,     -- Unix timestamp (ms)

    PRIMARY KEY (hash, service_id),
    FOREIGN KEY (service_id) REFERENCES services(id)
);

CREATE INDEX IF NOT EXISTS idx_embeddings_service ON embeddings(service_id);
