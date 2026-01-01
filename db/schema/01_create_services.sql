-- AI embedding service registry
--
-- Tracks which provider/model/version created embeddings.
-- Each embedding references a service to ensure compatibility.
--
-- When searching, filter by service_id to only compare embeddings
-- from the same vector space (same provider/model/dimensions).

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
