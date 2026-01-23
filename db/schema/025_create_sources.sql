-- Sources table: Identity mapping for flexible external IDs
--
-- Maps external source identifiers (integer or string) to internal integer IDs.
-- This enables:
--   - Integer IDs: Time-based, sortable (e.g., Unix timestamps)
--   - String IDs: UUIDs and other text identifiers
--
-- Each source is identified by (source_type, external_int) OR (source_type, external_text).
-- Exactly one of external_int or external_text is set per row.

CREATE TABLE IF NOT EXISTS sources (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_type TEXT NOT NULL,       -- Application-defined type
    external_int INTEGER,            -- Integer external ID (sortable)
    external_text TEXT,              -- String external ID (UUID, etc.)
    created_at INTEGER NOT NULL,

    -- Ensure exactly one type of external ID is set
    CHECK ((external_int IS NOT NULL AND external_text IS NULL) OR
           (external_int IS NULL AND external_text IS NOT NULL)),

    UNIQUE(source_type, external_int),
    UNIQUE(source_type, external_text)
);

CREATE INDEX IF NOT EXISTS idx_sources_type_int ON sources(source_type, external_int)
    WHERE external_int IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sources_type_text ON sources(source_type, external_text)
    WHERE external_text IS NOT NULL;
