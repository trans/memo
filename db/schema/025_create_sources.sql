-- Sources table: Identity mapping for flexible external IDs
--
-- Maps external source identifiers (integer or string) to internal integer IDs.
-- This enables:
--   - Integer IDs: Time-based, sortable (e.g., Unix timestamps)
--   - String IDs: UUIDs and other text identifiers
--   - No external ID: Memo-managed sources (e.g., file indexer)
--
-- Each source is identified by (source_type, external_int) OR (source_type, external_text),
-- or by internal id only when no external ID is provided.

CREATE TABLE IF NOT EXISTS sources (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_type TEXT NOT NULL,       -- Application-defined type
    external_int INTEGER,            -- Integer external ID (sortable, optional)
    external_text TEXT,              -- String external ID (UUID, etc., optional)
    external_blob BLOB,              -- Binary external ID (raw hash, binary UUID, optional)
    created_at INTEGER NOT NULL,

    -- External IDs are optional, but if provided, must be unique per source_type
    UNIQUE(source_type, external_int),
    UNIQUE(source_type, external_text),
    UNIQUE(source_type, external_blob)
);

CREATE INDEX IF NOT EXISTS idx_sources_type_int ON sources(source_type, external_int)
    WHERE external_int IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sources_type_text ON sources(source_type, external_text)
    WHERE external_text IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sources_type_blob ON sources(source_type, external_blob)
    WHERE external_blob IS NOT NULL;
