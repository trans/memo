# PostgreSQL support for Memo
#
# Require this file instead of or in addition to "memo" to enable
# PostgreSQL as a storage backend.
#
# Usage:
#   require "memo"
#   require "memo/pg"
#
#   memo = Memo::Service.new(
#     db_path: "postgres://user:pass@host/memo_db",
#     index_dir: "/var/memo/indices",
#     service: "mock"
#   )

require "pg"
require "./dialect/postgres"
require "./queries/postgres"

Memo::Dialect.register_pg { Memo::Dialect::Postgres.new }
Memo::Queries.register_pg { |db| Memo::Queries::Postgres.new(db) }
