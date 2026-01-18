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
    is_default INTEGER DEFAULT 0,     -- 1 if this is the default service
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_services_format ON services(format);
CREATE INDEX IF NOT EXISTS idx_services_default ON services(is_default);

-- Preload services
-- OpenAI text-embedding-3-small is the default for production use
INSERT OR IGNORE INTO services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('openai', 'openai', NULL, 'text-embedding-3-small', 1536, 8191, 1, 0);

-- Mock service for development/testing
INSERT OR IGNORE INTO services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('mock', 'mock', NULL, 'mock-8d', 8, 100, 0, 0);
