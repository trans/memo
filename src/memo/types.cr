# Type definitions for flexible source IDs
#
# ExternalId supports integer, string, and binary identifiers:
# - Int64: For time-based, sortable IDs (e.g., Unix timestamps)
# - String: For UUIDs and other text-based identifiers
# - Bytes: For binary IDs (raw hashes, binary UUIDs)
#
# The choice of ID type is per-source and auto-detected from the value provided.
# External IDs are optional - memo-managed sources may have no external ID.
module Memo
  alias ExternalId = Int64 | String | Bytes
end
