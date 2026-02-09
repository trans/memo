# Semantic Search Optimization: Projection Vectors

**Status:** TODO
**Priority:** Medium
**Effort:** ~2-4 hours

## Overview

Optimize semantic search performance using projection reference vectors to eliminate candidates before computing full cosine similarity. This reduces the number of full vector comparisons needed, providing significant speedup for large datasets.

## The Projection Method

### Core Idea

Project all embedding vectors onto a small set of reference vectors and store the scalar projections. The triangle inequality then allows safe elimination of candidates that cannot possibly meet the similarity threshold.

### How It Works

For normalized vectors (which we use with cosine similarity):

1. **Pick reference unit vectors** `r₁, r₂, ..., rₙ` (random orthogonal vectors work well)
2. **For each stored vector v**, compute and store projections: `s_v = v · r`
3. **When querying with q**, compute query projections: `s_q = q · r`
4. **Eliminate candidates** where `|s_v - s_q| > cutoff`
5. **Compute full cosine similarity** only for remaining candidates

### Why This Works

For unit vectors: `||a - b||² = 2(1 - cos(a,b))`

A projection distance can only be smaller than the true distance, so a large projection difference **guarantees** a large true distance.

**Example:** For cosine similarity `> 0.8`, cutoff = `√(2 × 0.2) ≈ 0.63`
Any pair with scalar difference `> 0.63` can be safely eliminated.


### Cutoff Values by Threshold

| Cosine Threshold | Cutoff Value |
|------------------|--------------|
| 0.9              | 0.45         |
| 0.8              | 0.63         |
| 0.7              | 0.77         |

### Multiple Projections

**Key improvement:** Store 2–4 projections instead of one. Take the max difference across projections—this gives much tighter filtering with minimal storage overhead.

### Expected Performance Gains

| Projections | Candidate Elimination |
|-------------|----------------------|
| 1           | 20–40%               |
| 2           | 40–60%               |
| 4           | 50–70%               |
| 8           | 70–85%               |

**Recommendation:** Use 4 projections for optimal balance of storage vs performance.

## Implementation Plan

### 1. Database Schema Changes

Add projection columns to the `meaning` table:

```sql
ALTER TABLE meaning ADD COLUMN proj1 REAL;
ALTER TABLE meaning ADD COLUMN proj2 REAL;
ALTER TABLE meaning ADD COLUMN proj3 REAL;
ALTER TABLE meaning ADD COLUMN proj4 REAL;

CREATE INDEX idx_proj1 ON meaning(proj1);
CREATE INDEX idx_proj2 ON meaning(proj2);
CREATE INDEX idx_proj3 ON meaning(proj3);
CREATE INDEX idx_proj4 ON meaning(proj4);
-- Or use a composite index: CREATE INDEX idx_projections ON meaning(proj1, proj2, proj3, proj4);
```

### 2. Generate Orthogonal Reference Vectors

Use orthogonalized random vectors for better coverage. Generate once and store persistently.

**Crystal implementation:**

```crystal
# Generate n orthogonal unit vectors of given dimension
def generate_reference_vectors(dim : Int32, n : Int32 = 4) : Array(Array(Float64))
  # Generate random matrix
  random_matrix = Array.new(dim) do
    Array.new(n) { Random.rand(-1.0..1.0) }
  end

  # Apply Gram-Schmidt orthogonalization
  orthogonal = [] of Array(Float64)

  n.times do |i|
    # Start with random vector
    v = (0...dim).map { |j| random_matrix[j][i] }.to_a

    # Subtract projections onto previous vectors
    orthogonal.each do |u|
      projection = dot_product(v, u)
      v = v.zip(u).map { |vi, ui| vi - projection * ui }
    end

    # Normalize
    magnitude = Math.sqrt(dot_product(v, v))
    v = v.map { |vi| vi / magnitude }

    orthogonal << v
  end

  orthogonal
end

private def dot_product(a : Array(Float64), b : Array(Float64)) : Float64
  a.zip(b).sum { |ai, bi| ai * bi }
end
```

### 3. Store Reference Vectors

Add to session_metadata table or create dedicated table:

```sql
CREATE TABLE IF NOT EXISTS projection_vectors (
    id INTEGER PRIMARY KEY,
    dimension INTEGER NOT NULL,
    vector BLOB NOT NULL,
    created_at INTEGER NOT NULL
);
```

### 4. Compute Projections During Embedding

Update `Database::Semantic.store_chunk()`:

```crystal
def store_chunk(
  db : DB::Database,
  text : String,
  embedding : Array(Float64),
  # ... other params ...
)
  # ... existing code ...

  # Load reference vectors (cached)
  ref_vectors = load_reference_vectors(db)

  # Compute projections
  projections = ref_vectors.map { |r| dot_product(embedding, r) }

  # Store with projections
  tx.connection.exec(
    "INSERT OR IGNORE INTO meaning (hash, embedding, token_count, created_at, proj1, proj2, proj3, proj4) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
    hash, embedding_blob, tokens, timestamp,
    projections[0], projections[1], projections[2], projections[3]
  )
end
```

### 5. Update Search with Projection Filtering

Modify `Database::Semantic.search()`:

```crystal
def search(
  db : DB::Database,
  embedding : Array(Float64),
  # ... other params ...
) : Array(SearchResult)
  # Load reference vectors
  ref_vectors = load_reference_vectors(db)

  # Compute query projections
  query_projections = ref_vectors.map { |r| dot_product(embedding, r) }

  # Compute cutoff based on min_score
  cutoff = compute_cutoff(min_score) + 0.01  # Add epsilon for safety

  # Filter using projections first
  db.query(
    <<-SQL,
      SELECT r.event_id, r.artifact_id, r.offset, r.size,
             m.hash, m.token_count, m.embedding
      FROM reference r
      JOIN meaning m ON r.hash = m.hash
      WHERE ABS(m.proj1 - ?) <= ?
        AND ABS(m.proj2 - ?) <= ?
        AND ABS(m.proj3 - ?) <= ?
        AND ABS(m.proj4 - ?) <= ?
      #{where_clause}
    SQL
    query_projections[0], cutoff,
    query_projections[1], cutoff,
    query_projections[2], cutoff,
    query_projections[3], cutoff
  ) do |rs|
    # ... rest of search logic (compute full cosine similarity) ...
  end
end

private def compute_cutoff(threshold : Float64, epsilon : Float64 = 0.01) : Float64
  Math.sqrt(2.0 * (1.0 - threshold)) + epsilon
end
```

## Important Guarantees

**No false negatives:** The projection method doesn't approximate anything. The triangle inequality guarantee is strict:
- If a vector **passes** the filter, it might be similar (need to check with full cosine similarity)
- If a vector **fails** the filter, it **cannot** be similar enough (safe to skip)
- **You never miss a true match**

### Caveats

1. **Floating point safety:** Use a slightly looser cutoff (add epsilon ~0.01) to avoid edge cases from floating point arithmetic
2. **Normalization:** The math assumes unit vectors. OpenAI embeddings are already normalized, but add a small margin if concerned
3. **Reference vector persistence:** Store reference vectors in the database. If regenerated, all projections become meaningless and must be recomputed

## Alternative: SQLite Vector Extension

**Consider:** [sqlite-vec](https://github.com/asg017/sqlite-vec) provides native vector operations in SQLite, including:
- Built-in cosine similarity
- Approximate Nearest Neighbor (ANN) search
- HNSW and IVF-Flat indices

**Trade-off:** Requires SQLite extension vs pure Crystal implementation with projection filtering.

## Migration Strategy

1. Add projection columns with default NULL
2. Generate and store reference vectors
3. Backfill projections for existing embeddings (can be done incrementally)
4. Update search to use projection filtering
5. Monitor performance improvement

## Success Metrics

- **Before:** Compute cosine similarity for all N embeddings
- **After:** Compute cosine similarity for ~30-50% of embeddings (with 4 projections)
- **Expected speedup:** 2-3x for typical queries
- **Storage overhead:** 4 × 4 bytes = 16 bytes per embedding (minimal)
