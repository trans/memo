module Memo
  # Reciprocal Rank Fusion (RRF) for combining ranked search results
  #
  # TODO: Decide on RRF utility approach:
  # 1. Remove entirely - too specialized, apps can implement (only ~20 lines)
  # 2. Make generic - accept any type with #id and #score (but Search::Result has chunk_id)
  # 3. Keep current - but requires conversion to RRF::Item (loses metadata)
  #
  # Current implementation loses Search::Result metadata (source_type, offset, etc.)
  # when converting to RRF::Item. Apps need to re-lookup full results after merge.
  #
  # RRF merges multiple ranked lists by computing a score based on rank position:
  #   score = 1 / (k + rank)
  #
  # Where k is a constant (typically 60) that reduces the impact of high ranks.
  #
  # ## Benefits over simple score merging:
  # - Rank-based, not score-based (handles different scoring scales)
  # - No score normalization needed
  # - Proven effective in information retrieval (IR research)
  #
  # ## Example:
  # ```
  # keyword_results = [
  #   RRF::Item.new(id: 1, score: 10.0),
  #   RRF::Item.new(id: 2, score: 8.0),
  # ]
  # semantic_results = [
  #   RRF::Item.new(id: 2, score: 0.95),
  #   RRF::Item.new(id: 3, score: 0.85),
  # ]
  # merged = RRF.merge([keyword_results, semantic_results])
  # # Result: [id=2 (in both lists), id=1, id=3]
  # ```
  module RRF
    extend self

    # Default k constant for RRF algorithm
    DEFAULT_K = 60

    # Result item for RRF merging
    #
    # Represents a single search result with ID and scores
    class Item
      property id : Int64
      property score : Float64      # Original score from source
      property rrf_score : Float64  # Computed RRF score (set by merge)

      def initialize(
        @id : Int64,
        @score : Float64
      )
        @rrf_score = 0.0
      end

      def to_s(io : IO)
        io << "RRF::Item(id=#{@id}, score=#{@score}, rrf=#{@rrf_score})"
      end
    end

    # Merge multiple ranked result lists using RRF
    #
    # Returns results sorted by RRF score (highest first)
    def merge(
      lists : Array(Array(Item)),
      k : Int32 = DEFAULT_K
    ) : Array(Item)
      # Aggregate scores by result ID
      scores = Hash(Int64, Float64).new(0.0)
      items = Hash(Int64, Item).new

      # For each ranked list, compute RRF scores
      lists.each do |list|
        list.each_with_index do |item, rank|
          # RRF score: 1 / (k + rank)
          # rank is 0-indexed, so first item gets 1/(k+0)
          rrf_score = 1.0 / (k + rank)

          scores[item.id] += rrf_score

          # Keep the first occurrence's item
          items[item.id] ||= item
        end
      end

      # Sort by RRF score (descending)
      sorted = scores.to_a.sort_by { |_id, score| -score }

      # Build result list with RRF scores
      sorted.map do |id, rrf_score|
        item = items[id]
        item.rrf_score = rrf_score
        item
      end
    end
  end
end
