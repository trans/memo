module Copious
  module Semantic
    # Reciprocal Rank Fusion (RRF) for combining ranked search results.
    #
    # RRF merges multiple ranked lists by computing a score based on rank position:
    #   score = 1 / (k + rank)
    #
    # Where k is a constant (typically 60) that reduces the impact of high ranks.
    #
    # ## Benefits over simple score merging:
    # - Rank-based, not score-based (handles different scoring scales)
    # - No score normalization needed
    # - Proven effective in information retrieval
    #
    # ## Example:
    # ```
    # keyword_results = [
    #   ResultItem.new(id: 1, score: 10.0, data: {...}),
    #   ResultItem.new(id: 2, score: 8.0, data: {...}),
    # ]
    # semantic_results = [
    #   ResultItem.new(id: 2, score: 0.95, data: {...}),
    #   ResultItem.new(id: 3, score: 0.85, data: {...}),
    # ]
    # merged = RRF.merge([keyword_results, semantic_results])
    # # Result: [id=2 (in both), id=1, id=3]
    # ```
    module RRF
      extend self

      # Default k constant for RRF algorithm.
      DEFAULT_K = 60

      # Merge multiple ranked result lists using RRF.
      #
      # Returns results sorted by RRF score (highest first).
      def merge(
        lists : Array(Array(ResultItem)),
        k : Int32 = DEFAULT_K
      ) : Array(ResultItem)
        # Aggregate scores by result ID
        scores = Hash(Int64, Float64).new(0.0)
        metadata = Hash(Int64, ResultItem).new

        # For each ranked list, compute RRF scores
        lists.each do |list|
          list.each_with_index do |item, rank|
            # RRF score: 1 / (k + rank)
            # rank is 0-indexed, so first item gets 1/(k+0)
            rrf_score = 1.0 / (k + rank)

            scores[item.id] += rrf_score

            # Keep the first occurrence's metadata
            metadata[item.id] ||= item
          end
        end

        # Sort by RRF score (descending)
        sorted = scores.to_a.sort_by { |_id, score| -score }

        # Build result list with RRF scores
        sorted.map do |id, rrf_score|
          item = metadata[id]
          item.rrf_score = rrf_score
          item
        end
      end

      # Result item for RRF merging.
      #
      # Represents a single search result with ID, original score,
      # and computed RRF score.
      class ResultItem
        property id : Int64
        property score : Float64      # Original score from source
        property rrf_score : Float64  # Computed RRF score
        property data : Hash(String, JSON::Any)  # Result metadata

        def initialize(
          @id : Int64,
          @score : Float64,
          @data : Hash(String, JSON::Any) = {} of String => JSON::Any
        )
          @rrf_score = 0.0
        end

        # For debugging
        def to_s(io : IO)
          io << "ResultItem(id=#{@id}, score=#{@score}, rrf=#{@rrf_score})"
        end
      end
    end
  end
end
