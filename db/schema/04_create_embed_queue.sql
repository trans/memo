-- Embedding queue: Tracks pending embedding work
--
-- Allows batch processing of embeddings. Applications enqueue sources that need
-- embedding, and a background processor can work through the queue.
--
-- Status codes:
--   -1 = pending (not yet processed)
--    0 = success (embedded successfully)
--   >0 = error codes (HTTP errors like 429, 503, or custom app errors)
--
-- The queue supports retry logic via the attempts counter, allowing applications
-- to implement exponential backoff or retry limits.

CREATE TABLE IF NOT EXISTS embed_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_type TEXT NOT NULL,       -- What kind of thing to embed
    source_id INTEGER NOT NULL,      -- ID of thing to embed
    text TEXT,                       -- Pre-extracted text (optional, for efficiency)
    status INTEGER NOT NULL DEFAULT -1,  -- -1=pending, 0=success, >0=error
    error_message TEXT,              -- Error details if status > 0
    attempts INTEGER NOT NULL DEFAULT 0, -- Retry counter
    created_at INTEGER NOT NULL,     -- Unix timestamp (ms) when enqueued
    processed_at INTEGER,            -- Unix timestamp (ms) when processed

    UNIQUE(source_type, source_id)
);

-- Index for finding pending items
CREATE INDEX IF NOT EXISTS idx_queue_pending ON embed_queue(status) WHERE status = -1;

-- Index for finding failed items to retry
CREATE INDEX IF NOT EXISTS idx_queue_retries ON embed_queue(status, attempts) WHERE status > 0;
