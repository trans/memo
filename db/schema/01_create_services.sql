-- AI embedding service registry
--
-- Named service configurations for embedding providers.
-- Each embedding references a service to ensure compatibility.
--
-- When searching, filter by service_id to only compare embeddings
-- from the same vector space (same format/model/dimensions).

CREATE TABLE IF NOT EXISTS services (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,        -- User-defined service name (lookup key)
    format TEXT NOT NULL,             -- API format (e.g., "openai", "mock")
    base_url TEXT,                    -- Optional custom API endpoint
    model TEXT NOT NULL,              -- Model name (e.g., "text-embedding-3-small")
    dimensions INTEGER NOT NULL,      -- Vector dimensions (e.g., 1536)
    max_tokens INTEGER NOT NULL,      -- Model's maximum tokens per chunk
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_services_format ON services(format);
