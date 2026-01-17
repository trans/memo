# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
