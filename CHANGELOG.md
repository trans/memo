# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.1] - 2026-01-24

### Changed
- **Vocabulary now builds incrementally during index**
  - Words are extracted and embedded alongside chunks automatically
  - No need to run `build-vocab` separately
  - Existing word frequencies updated on each index
  - `build-vocab` remains available for full rebuild

### Added
- `--no-vocab` CLI flag to disable vocabulary building during index
- `build_vocab` option in Service initialization (default true)

## [0.5.0] - 2026-01-22

### Added
- **Vocabulary table for word-level semantic similarity**
  - `build-vocab` CLI command extracts unique words from indexed content
  - `like` CLI command finds semantically similar words
  - `build_vocab()`, `like()`, `vocab_stats()`, `clear_vocab()` API methods
  - Stopword filtering, word normalization, frequency tracking
  - Batch embedding for efficient vocabulary building

### Changed
- **CLI refactored to use CLJ library** for argument parsing
  - Replaced custom parser with schema-driven CLJ
  - Added `key:value` and `--key value` syntax (in addition to `key=value`)
  - Nested subcommand support via CLJ's hierarchical CLI feature
  - Reduced CLI code by ~330 lines

### Fixed
- `Input.bool` now correctly handles `false` values (was raising error)

### Removed
- Custom `parser.cr` and `help.cr` (functionality now provided by CLJ)

## [0.4.0] - 2026-01-21

### Added
- **CLI tool** with JSON Schema validation
  - Commands: `index`, `search`, `delete`, `stats`
  - Service management: `service list`, `service use`, `service create`, `service delete`
  - `key=value` argument syntax (`memo search query="test"`)
  - JSON via stdin with `--stdin` flag
  - Human-readable output by default, `--json` for machine output
  - Auto-generated help from schema
  - Environment variable support (`MEMO_API_KEY`, `OPENAI_API_KEY`, `VOYAGE_API_KEY`)
  - Custom API endpoint support via `endpoint` parameter
  - Positional argument support for single-arg commands (`memo service use voyage`)

### Changed
- Service commands now use subcommand pattern (`memo service create` instead of `memo service-create`)
- Chunking rewritten with range-based offset tracking for exact SUBSTR compatibility
- `tokens_per_byte` now updates in-memory config immediately (no restart needed)

### Fixed
- Remove invalid FK constraint from chunks table (embeddings has composite PK)
- `delete()` now removes texts/texts_fts entries (prevents resurrection on reindex)
- Whitespace-only input now returns empty chunks (was incorrectly producing 1 chunk)
- `create_chunk` returns 0 when insert is ignored (accurate insert counts)
- Error on unknown subcommand instead of silently running default
- Schema comments updated to reflect soft reference design

## [0.3.0] - 2026-01-20

### Changed
- Consolidated two database files (embeddings.db + text.db) into single database file
- Removed ATTACH DATABASE complexity - all tables now in one database
- Replaced `data_dir` parameter with `db_path` - specify full path instead of directory

## [0.2.1] - 2026-01-18

### Added
- Adaptive `tokens_per_byte` ratio for chunking - self-calibrates using exponential moving average instead of hardcoded chars/4
- HTTP timeouts for embedding providers (30s connect, 120s read)

### Fixed
- Chunk offsets now track actual positions in source text (enables accurate SUBSTR extraction)
- Embedding provider responses sorted by index to prevent input/output misalignment
- `delete` now returns actual chunk count, not distinct hash count
- `store_embedding` returns false when row already exists (was always true)
- README examples use `format:` instead of non-existent `provider:` parameter

## [0.2.0] - 2025-01-18

### Added
- Voyage AI embedding provider (voyage-3, voyage-3-lite, voyage-code-3)
- Default service support with `use_service` method
- Service CRUD methods (`create_service`, `get_service`, `list_services`, `delete_service`)

### Fixed
- SQLite3 segfault on close when using ATTACH (now uses setup_connection for connection pool compatibility)
- FTS5 MATCH queries failing with "no such column" error
- `index_batch` incorrectly counting documents with empty text

## [0.1.0] - 2025-01-17

### Added
- Initial release
- `Memo::Service` - High-level API for indexing and searching
- OpenAI embedding provider (text-embedding-3-small, text-embedding-3-large)
- Mock provider for testing
- Configurable model and dimensions for embedding providers
- Smart text chunking with configurable parameters
- Cosine similarity search with filtering (source_type, source_id, pair_id, parent_id)
- Content deduplication via SHA256 hashing
- Service tracking to ensure compatible vector spaces
- Usage tracking (match_count, read_count)
- RRF (Reciprocal Rank Fusion) for hybrid search
- ATTACH support for cross-database queries
- **Embed queue** for background processing with retry support
  - `enqueue`, `enqueue_batch` - Add items to queue
  - `process_queue`, `process_queue_async` - Process queued items
  - `queue_stats` - Get queue status counts
  - `clear_queue`, `clear_completed_queue` - Queue management
- **Reindex** support for re-embedding existing content
  - `reindex(source_type)` - Re-embed from stored text
  - `reindex(source_type, &block)` - Re-embed with custom text provider
- All indexing routes through queue for automatic retry on failures
