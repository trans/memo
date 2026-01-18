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

-- OpenAI models
INSERT OR IGNORE INTO services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('openai', 'openai', NULL, 'text-embedding-3-small', 1536, 8191, 1, 0);

INSERT OR IGNORE INTO services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('openai/text-embedding-3-large', 'openai', NULL, 'text-embedding-3-large', 3072, 8191, 0, 0);

INSERT OR IGNORE INTO services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('openai/text-embedding-ada-002', 'openai', NULL, 'text-embedding-ada-002', 1536, 8191, 0, 0);

-- Voyage AI models
INSERT OR IGNORE INTO services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('voyage', 'voyage', NULL, 'voyage-3', 1024, 32000, 0, 0);

INSERT OR IGNORE INTO services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('voyage/voyage-3-lite', 'voyage', NULL, 'voyage-3-lite', 512, 32000, 0, 0);

INSERT OR IGNORE INTO services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('voyage/voyage-code-3', 'voyage', NULL, 'voyage-code-3', 1024, 32000, 0, 0);

INSERT OR IGNORE INTO services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('voyage/voyage-finance-2', 'voyage', NULL, 'voyage-finance-2', 1024, 32000, 0, 0);

INSERT OR IGNORE INTO services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('voyage/voyage-law-2', 'voyage', NULL, 'voyage-law-2', 1024, 32000, 0, 0);

-- Mock service for development/testing
INSERT OR IGNORE INTO services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('mock', 'mock', NULL, 'mock-8d', 8, 100, 0, 0);
