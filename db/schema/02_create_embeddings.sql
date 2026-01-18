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
