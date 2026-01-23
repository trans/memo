# Type definitions for flexible source IDs
#
# ExternalId supports both integer and string identifiers:
# - Int64: For time-based, sortable IDs (e.g., Unix timestamps)
# - String: For UUIDs and other text-based identifiers
#
# The choice of ID type is per-source and auto-detected from the value provided.
module Memo
  alias ExternalId = Int64 | String
end
