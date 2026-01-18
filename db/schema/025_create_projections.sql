-- =============================================================================
-- Projection vectors: Random orthogonal vectors for fast similarity filtering
--
-- Stores k random orthogonal unit vectors per service. These are generated once
-- when a service is first registered and used to compute low-dimensional
-- projections of embeddings for fast pre-filtering during search.
--
-- Each embedding's projection onto these vectors approximates its position in
-- the full vector space, allowing quick elimination of dissimilar candidates
-- before expensive full cosine similarity computation.
--
-- Vectors are stored as BLOBs in the same format as embeddings (little-endian
-- Float32). Each vector has the same dimension as the service's embeddings.
-- =============================================================================

CREATE TABLE IF NOT EXISTS projection_vectors (
    service_id INTEGER PRIMARY KEY,  -- FK to services table (one row per service)
    vec_0 BLOB NOT NULL,             -- Random orthogonal unit vector
    vec_1 BLOB NOT NULL,
    vec_2 BLOB NOT NULL,
    vec_3 BLOB NOT NULL,
    vec_4 BLOB NOT NULL,
    vec_5 BLOB NOT NULL,
    vec_6 BLOB NOT NULL,
    vec_7 BLOB NOT NULL,
    created_at INTEGER NOT NULL,

    FOREIGN KEY (service_id) REFERENCES services(id)
);

-- =============================================================================
-- Projections: Low-dimensional projections for fast similarity filtering
--
-- Stores dot products of each embedding with the service's projection vectors.
-- During search, query projections are compared against stored projections to
-- quickly filter candidates before full cosine similarity computation.
--
-- The projection values approximate position in the embedding space. Embeddings
-- with similar projections are likely to have high cosine similarity.
-- =============================================================================

CREATE TABLE IF NOT EXISTS projections (
    hash BLOB PRIMARY KEY,           -- FK to embeddings(hash)
    proj_0 REAL NOT NULL,            -- Dot product with vec_0
    proj_1 REAL NOT NULL,            -- Dot product with vec_1
    proj_2 REAL NOT NULL,            -- Dot product with vec_2
    proj_3 REAL NOT NULL,            -- Dot product with vec_3
    proj_4 REAL NOT NULL,            -- Dot product with vec_4
    proj_5 REAL NOT NULL,            -- Dot product with vec_5
    proj_6 REAL NOT NULL,            -- Dot product with vec_6
    proj_7 REAL NOT NULL,            -- Dot product with vec_7

    FOREIGN KEY (hash) REFERENCES embeddings(hash)
);
