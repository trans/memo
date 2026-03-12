# PostgreSQL Backend Support

## Goal

Add PostgreSQL as an alternative storage backend to SQLite, enabling two product tiers:

- **ICPK Personal** — SQLite per-project, zero config, local-only
- **ICPK Professional** — PostgreSQL, remotely accessible (e.g. via Tailscale)

USearch HNSW remains the vector search engine in both cases. Only metadata/text storage swaps.

## Architecture: Dialect Adapter Pattern

A thin `Dialect` module encapsulates SQL syntax differences. Most queries are already cross-database compatible — only ~15 patterns diverge.

```
src/memo/dialect/
  base.cr       # Abstract interface
  sqlite.cr     # Current SQLite behavior extracted
  postgres.cr   # PostgreSQL equivalents
```

The dialect is attached to `DB::Database` via the existing extension pattern (`db.memo_dialect`), so every module can access it without constructor changes.

## SQLite-Specific Patterns Requiring Abstraction

| Pattern | Locations | PostgreSQL Equivalent |
|---------|-----------|---------------------|
| `last_insert_rowid()` | storage.cr, source_registry.cr (x4), service_provider.cr | `INSERT ... RETURNING id` |
| `INSERT OR IGNORE` | storage.cr (x2), schema seed data | `INSERT ... ON CONFLICT DO NOTHING` |
| `INSERT OR REPLACE` | files.cr, vocab.cr (x2) | `INSERT ... ON CONFLICT (...) DO UPDATE SET` |
| FTS5 virtual table | schema, service.cr | `tsvector` column + GIN index |
| FTS5 `MATCH` operator | search.cr | `@@` with `to_tsquery()` |
| Implicit `rowid` | storage.cr, search.cr, clustering.cr | Explicit `rowid BIGSERIAL UNIQUE` column |
| `pragma_database_list` | service.cr | Not needed (connection string) |
| `BLOB` type | schema | `BYTEA` |
| `INTEGER PRIMARY KEY AUTOINCREMENT` | schema | `BIGSERIAL PRIMARY KEY` |
| `REAL` type | schema | `DOUBLE PRECISION` |

**Compatible patterns (no change needed):**
- Parameter placeholders (`?`) — Crystal's `pg` driver auto-translates to `$N`
- `SUBSTR()` — identical semantics
- `Bytes` type mapping — `pg` driver maps `BYTEA` to `Bytes`
- Transactions — `db.transaction` works identically
- `ON CONFLICT(...) DO UPDATE SET` — already used in service.cr, PG-compatible

## Implementation Steps

### Step 1: Create Dialect Interface

New file `src/memo/dialect/base.cr` with abstract methods:

- `schema_statements(prefix)` — DDL for schema creation
- `insert_returning_id(db, sql, *args)` — insert and return generated ID
- `insert_or_ignore_sql(table, columns, placeholders)` — conflict-ignoring insert
- `upsert_sql(table, columns, placeholders, conflict_cols, update_cols)` — upsert
- `fts_create_sql(prefix)` — FTS index/table creation
- `fts_insert(db, prefix, source_id, content)` — add to FTS index
- `fts_delete(db, prefix, source_id)` — remove from FTS index
- `fts_join_sql(prefix)` — JOIN clause for FTS filtering
- `fts_match_sql(prefix)` — WHERE clause for FTS match
- `db_file_path(db)` — resolve local file path (SQLite) or nil (PG)

### Step 2: Extract SQLite Dialect

New file `src/memo/dialect/sqlite.cr` implementing the interface with current behavior. This is a pure refactor — no behavior change, all existing tests must still pass.

### Step 3: Refactor Modules to Use Dialect

Thread `db.memo_dialect` through these files:

- **`storage.cr`** — `register_service`, `store_embedding`, `create_chunk` (last_insert_rowid, INSERT OR IGNORE)
- **`source_registry.cr`** — all `resolve` and `create` methods (last_insert_rowid x4)
- **`service_provider.cr`** — `create` method (last_insert_rowid)
- **`files.cr`** — `store` method (INSERT OR REPLACE)
- **`vocab.cr`** — `store_batch`, `store_word` (INSERT OR REPLACE)
- **`search.cr`** — `search_filtered` (FTS5 MATCH join, rowid references)
- **`service.cr`** — `store_source_text_internal`, `delete_source_text_internal` (FTS5 operations), constructor (pragma_database_list)
- **`database.cr`** — `load_schema` (use dialect's schema_statements)

Each file can be refactored independently. Existing tests validate correctness after each change.

### Step 4: PostgreSQL Schema

New file `db/schema/memo_schema_pg.sql` with:

- `BIGSERIAL PRIMARY KEY` instead of `INTEGER PRIMARY KEY AUTOINCREMENT`
- `BYTEA` instead of `BLOB`
- `DOUBLE PRECISION` instead of `REAL`
- Explicit `rowid BIGSERIAL UNIQUE` on embeddings table
- `content_tsv TSVECTOR` column on texts table with GIN index
- Trigger to auto-populate `content_tsv` on insert/update
- Seed data using `ON CONFLICT DO NOTHING`

### Step 5: Implement PostgreSQL Dialect

New file `src/memo/dialect/postgres.cr` implementing the interface.

The FTS translation is the most complex piece:
- FTS5 `MATCH "term1 term2"` → `to_tsquery('term1 & term2')`
- FTS5 `MATCH "term1 OR term2"` → `to_tsquery('term1 | term2')`
- FTS5 prefix queries `term*` → `to_tsquery('term:*')`

### Step 6: USearch Index Path for PostgreSQL

For PostgreSQL there's no local `.db` file to derive the index path from.

- Add `index_dir : String?` parameter to `Service` constructors
- SQLite: derive from `db_path` as today (default)
- PostgreSQL: require `index_dir` or default to `~/.memo/indices/`
- Update `usearch_index.cr` with `index_path(dir, format, model, dimensions)` overload

### Step 7: Entry Points and Dependencies

Two require paths to avoid forcing `pg` as a compile-time dependency:

- `require "memo"` — SQLite only (current behavior, no change)
- `require "memo/pg"` — adds PostgreSQL support

New files:
- `src/memo/pg.cr` — `require "pg"` + `require "./memo/dialect/postgres"`

Add `pg` shard as optional dependency in `shard.yml`.

### Step 8: Connection String Routing

Update `Service` constructor to detect backend from connection string:

```crystal
# Auto-detects dialect from URI scheme
Memo::Service.new(db_path: "sqlite3:///path/to/memo.db")
Memo::Service.new(db_path: "postgres://user:pass@host/memo", index_dir: "/var/memo/indices")
```

Factory in `src/memo/dialect.cr`:
```crystal
def self.for(connection_string : String) : Base
  if connection_string.starts_with?("postgres")
    Postgres.new
  else
    SQLite.new
  end
end
```

## Implementation Notes

Changes from the original plan during implementation:

- **Configurable table prefix removed** — The `table_prefix` system was removed entirely. All tables are hardcoded with `memo_` prefix. Schema files are the single source of truth for table names; all SQL in code uses literal strings. This eliminated ~300 lines of interpolation overhead.
- **USearch API simplified** — `USearchIndex` methods now take a pre-computed path string instead of `(db_path, format, model, dimensions)`. `Service` stores `@index_path` and passes it directly. New `index_path_in_dir` method for PG backend (no db file to derive from).
- **Connection string routing** — `Service.new(db_path: "postgres://...")` auto-detects PG and sets dialect. `Database.create` also handles both backends. Default USearch index dir for PG: `~/.memo/indices/`.
- **FTS translation** — PG uses `plainto_tsquery('english', ?)` for now. This handles simple term queries but not FTS5 advanced syntax (AND/OR/NOT/prefix*). Full translation is a future enhancement.
- **`pg` shard** — Not added to `shard.yml` as a dependency. Users add it themselves when they `require "memo/pg"`. The runtime factory pattern means PG code is never compiled unless explicitly required.

## Testing Strategy

- All 116 existing specs pass against SQLite dialect (regression verified)
- PostgreSQL integration tests require a live PG instance (future: `with_test_pg_service` helper, skipped in CI without PG)
- FTS query translation beyond `plainto_tsquery` is a future enhancement

## Risks

- **FTS query translation** — FTS5 and `to_tsquery` have different syntax. Current PG implementation uses `plainto_tsquery` which handles simple term matching but not boolean operators or prefix queries. Mitigation: document limitations, enhance later.
- **rowid stability** — SQLite rowids are stable; PG `eid BIGSERIAL` is also stable (never reused). USearch keys are safe in both backends.
- **Performance** — PG adds network latency for metadata queries. Mitigation: batch operations where possible, USearch stays in-process for vector search.
- **USearch index locality** — PG backend stores USearch index files locally (`~/.memo/indices/`). In a multi-machine setup, each machine has its own index that must be rebuilt if lost. The index is a cache over the embeddings in PG, so rebuild is lossless.

## Files Changed (Summary)

**New files:**
- `src/memo/dialect/base.cr` — Abstract dialect interface (10 abstract methods)
- `src/memo/dialect/sqlite.cr` — SQLite dialect (FTS5, last_insert_rowid, INSERT OR IGNORE/REPLACE)
- `src/memo/dialect/postgres.cr` — PostgreSQL dialect (RETURNING, ON CONFLICT, tsvector, $$-aware splitting)
- `src/memo/dialect.cr` — Dialect factory with runtime PG registration
- `src/memo/pg.cr` — PostgreSQL entry point (`require "memo/pg"`)
- `db/schema/memo_schema_pg.sql` — PostgreSQL schema (BIGSERIAL, BYTEA, tsvector/GIN, trigger)

**Modified files:**
- `src/memo/storage.cr` — Use dialect for inserts, rowid column
- `src/memo/source_registry.cr` — Use dialect for insert_returning_id
- `src/memo/service_provider.cr` — Use dialect for insert_returning_id, upsert
- `src/memo/files.cr` — Use dialect for upsert
- `src/memo/vocab.cr` — Use dialect for upsert
- `src/memo/search.cr` — Use dialect for FTS join/where, rowid column
- `src/memo/service.cr` — Connection string routing, index_path, removed table_prefix
- `src/memo/database.cr` — PG-aware create(), dialect-driven schema init
- `src/memo/usearch_index.cr` — Simplified path-based API, DEFAULT_INDEX_DIR
- `src/memo.cr` — Removed memo_table_prefix, added dialect require
