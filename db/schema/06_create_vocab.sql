-- =============================================================================
-- Vocabulary table: Word-level embeddings for concept similarity
--
-- Stores unique words extracted from indexed content with their embeddings.
-- Enables word-level semantic search via `memo like "word"`.
--
-- Words are extracted during `build-vocab` command:
-- 1. Query all text from texts table
-- 2. Tokenize and normalize
-- 3. Filter stopwords, short/long words, numbers
-- 4. Batch embed unique terms
-- 5. Store in vocab table
-- =============================================================================

CREATE TABLE IF NOT EXISTS vocab (
    word TEXT NOT NULL,              -- Normalized word (lowercase, stripped)
    service_id INTEGER NOT NULL,     -- FK to services table
    embedding BLOB NOT NULL,         -- Vector embedding (Float32, same as embeddings)
    frequency INTEGER DEFAULT 1,     -- How often word appears in corpus
    created_at INTEGER NOT NULL,     -- Unix timestamp (ms)

    PRIMARY KEY (word, service_id),
    FOREIGN KEY (service_id) REFERENCES services(id)
);

CREATE INDEX IF NOT EXISTS idx_vocab_service ON vocab(service_id);
