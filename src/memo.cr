require "db"
require "sqlite3"
require "digest/sha256"

require "./memo/config"
require "./memo/database"
require "./memo/chunking"
require "./memo/providers/base"
require "./memo/providers/openai"
require "./memo/providers/mock"
require "./memo/storage"
require "./memo/rrf"
require "./memo/search"
require "./memo/service"

# Memo - Semantic search and vector storage library
#
# A focused library for chunking, embedding, and searching text using
# vector similarity. Designed to be embedded in applications that need
# semantic search capabilities.
#
# ## Quick Start
#
# ```
# require "memo"
#
# # Initialize database
# db = DB.open("sqlite3://app.db")
# Memo::Database.load_schema(db)
#
# # Create service (handles embeddings internally)
# memo = Memo::Service.new(
#   db: db,
#   provider: "openai",
#   api_key: ENV["OPENAI_API_KEY"]
# )
#
# # Index a document
# memo.index(
#   source_type: "document",
#   source_id: 42,
#   text: "Your document text..."
# )
#
# # Search
# results = memo.search(query: "search query", limit: 10)
# ```
#
# ## API
#
# The primary API is `Memo::Service` which provides:
# - `index()` - Index documents with automatic chunking and embedding
# - `search()` - Search with automatic query embedding
# - `mark_as_read()` - Track chunk usage
#
# Internal modules (Storage, Search, Chunking, RRF) remain accessible
# for advanced use cases but Service is the recommended entry point.
module Memo
  VERSION = "0.1.0"

  # Global configuration
  class_property table_prefix : String = "memo_"

  # Configure memo (optional - has sensible defaults)
  def self.configure
    yield self
  end
end
