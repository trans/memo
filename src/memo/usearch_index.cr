require "usearch"

module Memo
  # USearch HNSW index management for fast approximate nearest neighbor search.
  #
  # Wraps USearch index lifecycle: file naming, open/save/close, type conversion,
  # and vector operations. All Float64↔Float32 conversion happens here.
  #
  # One index per service (isolated vector spaces). Index files are stored
  # alongside the SQLite database, named by format, model, and dimensions:
  #   openai--text-embedding-3-small--1536.usearch
  module USearchIndex
    extend self

    # Build the index file path for a service.
    #
    # Path: {db_dir}/{format}--{model}--{dimensions}.usearch
    # Path-unsafe characters in format/model are replaced with hyphens.
    def index_path(db_path : String, format : String, model : String, dimensions : Int32) : String
      dir = File.dirname(db_path)
      safe_format = format.gsub(/[^a-zA-Z0-9\-\.]/, "-")
      safe_model = model.gsub(/[^a-zA-Z0-9\-\.]/, "-")
      File.join(dir, "#{safe_format}--#{safe_model}--#{dimensions}.usearch")
    end

    # Open or create a USearch index for a service.
    #
    # If the index file exists on disk, loads it. Otherwise creates a new
    # empty index with cosine metric and f16 quantization.
    def open(db_path : String, format : String, model : String, dimensions : Int32) : USearch::Index
      path = index_path(db_path, format, model, dimensions)
      if File.exists?(path)
        USearch::Index.load(path, dimensions: dimensions, metric: :cos, quantization: :f16)
      else
        USearch::Index.new(dimensions: dimensions, metric: :cos, quantization: :f16)
      end
    end

    # Save the index to disk.
    def save(index : USearch::Index, db_path : String, format : String, model : String, dimensions : Int32)
      path = index_path(db_path, format, model, dimensions)
      index.save(path)
    end

    # Save and close the index, freeing resources.
    def close(index : USearch::Index, db_path : String, format : String, model : String, dimensions : Int32)
      save(index, db_path, format, model, dimensions) rescue nil
      index.close
    end

    # Delete the index file from disk.
    def delete_file(db_path : String, format : String, model : String, dimensions : Int32)
      path = index_path(db_path, format, model, dimensions)
      File.delete(path) if File.exists?(path)
    end

    # Convert Float64 array to Float32 array for USearch.
    def to_f32(embedding : Array(Float64)) : Array(Float32)
      embedding.map(&.to_f32)
    end

    # Add a vector to the index.
    #
    # Key is the SQLite rowid from the embeddings table.
    # Embedding is converted from Float64 to Float32 at this boundary.
    def add(index : USearch::Index, key : UInt64, embedding : Array(Float64))
      index.add(key, to_f32(embedding))
    end

    # Remove a vector from the index by key.
    def remove(index : USearch::Index, key : UInt64)
      index.remove(key) if index.contains?(key)
    end

    # Search for k nearest neighbors (unfiltered).
    #
    # Returns USearch::SearchResult array with keys and distances.
    # Cosine distance = 1 - similarity, so similarity = 1 - distance.
    def search(index : USearch::Index, query : Array(Float64), k : Int32) : Array(USearch::SearchResult)
      index.search(to_f32(query), k: k)
    end

    # Search with a filter predicate on keys.
    #
    # Only results where the filter block returns true are included.
    # Use this with a Set of valid rowids from SQL pre-filtering.
    def filtered_search(index : USearch::Index, query : Array(Float64), k : Int32, &filter : UInt64 -> Bool) : Array(USearch::SearchResult)
      index.filtered_search(to_f32(query), k: k, &filter)
    end

    # Retrieve a vector from the index by key.
    #
    # Returns Float64 array for compatibility with the rest of Memo,
    # or nil if the key doesn't exist.
    def get_vector(index : USearch::Index, key : UInt64) : Array(Float64)?
      vec_f32 = index.get(key)
      return nil unless vec_f32
      vec_f32.map(&.to_f64)
    end
  end
end
