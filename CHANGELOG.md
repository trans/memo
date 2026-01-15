# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2025-01-15

### Added
- Initial release
- `Memo::Service` - High-level API for indexing and searching
- OpenAI embedding provider (text-embedding-3-small)
- Mock provider for testing
- Smart text chunking with configurable parameters
- Cosine similarity search with filtering (source_type, source_id, pair_id, parent_id)
- Content deduplication via SHA256 hashing
- Service tracking to ensure compatible vector spaces
- Usage tracking (match_count, read_count)
- RRF (Reciprocal Rank Fusion) for hybrid search
- ATTACH support for cross-database queries
