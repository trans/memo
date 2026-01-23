module Memo::CLI
  # Global options merged into all command schemas via CLJ.merge
  GLOBAL_SCHEMA = %({
    "type": "object",
    "properties": {
      "db":      {"type": "string",  "short": "d", "description": "Database path", "default": "memo.db"},
      "service": {"type": "string",  "short": "s", "description": "Service name"},
      "api-key": {"type": "string",  "short": "k", "description": "API key"},
      "json":    {"type": "boolean", "short": "j", "description": "Output as JSON"}
    }
  })

  # Command schemas
  INDEX_SCHEMA = %({
    "type": "object",
    "properties": {
      "source-type": {"type": "string",  "description": "Source type identifier (e.g., article, note)"},
      "source-id":   {"oneOf": [{"type": "integer"}, {"type": "string"}], "description": "Unique source ID (integer or string/UUID)"},
      "text":        {"type": "string",  "description": "Text content to index"},
      "pair-id":     {"oneOf": [{"type": "integer"}, {"type": "string"}], "description": "Related source ID"},
      "parent-id":   {"oneOf": [{"type": "integer"}, {"type": "string"}], "description": "Parent source ID for hierarchies"}
    },
    "required": ["source-type", "source-id", "text"]
  })

  SEARCH_SCHEMA = %({
    "type": "object",
    "properties": {
      "query":        {"type": "string",  "description": "Search query text"},
      "limit":        {"type": "integer", "default": 10, "description": "Maximum number of results"},
      "min-score":    {"type": "number",  "default": 0.7, "description": "Minimum similarity score (0.0-1.0)"},
      "source-type":  {"type": "string",  "description": "Filter by source type"},
      "source-id":    {"oneOf": [{"type": "integer"}, {"type": "string"}], "description": "Filter by source ID (integer or string/UUID)"},
      "include-text": {"type": "boolean", "default": true, "description": "Include chunk text in results"}
    },
    "required": ["query"]
  })

  DELETE_SCHEMA = %({
    "type": "object",
    "properties": {
      "source-id":   {"oneOf": [{"type": "integer"}, {"type": "string"}], "description": "Source ID to delete (integer or string/UUID)"},
      "source-type": {"type": "string",  "description": "Filter deletion by source type"}
    },
    "required": ["source-id"]
  })

  STATS_SCHEMA = %({
    "type": "object",
    "properties": {}
  })

  LIKE_SCHEMA = %({
    "type": "object",
    "positional": ["query"],
    "properties": {
      "query":     {"type": "string",  "description": "Word or phrase to find similar concepts"},
      "limit":     {"type": "integer", "default": 10, "description": "Maximum number of results"},
      "min-score": {"type": "number",  "default": 0.5, "description": "Minimum similarity score (0.0-1.0)"}
    },
    "required": ["query"]
  })

  # Service subcommand schemas
  SERVICE_LIST_SCHEMA = %({
    "type": "object",
    "properties": {}
  })

  SERVICE_USE_SCHEMA = %({
    "type": "object",
    "positional": ["name"],
    "properties": {
      "name": {"type": "string", "description": "Service name to set as default"}
    },
    "required": ["name"]
  })

  SERVICE_CREATE_SCHEMA = %({
    "type": "object",
    "properties": {
      "name":       {"type": "string",  "description": "Unique service name"},
      "format":     {"type": "string",  "description": "Provider format (openai, voyage)"},
      "model":      {"type": "string",  "description": "Model name (e.g., text-embedding-3-small)"},
      "dimensions": {"type": "integer", "description": "Embedding dimensions (e.g., 1536)"},
      "max-tokens": {"type": "integer", "description": "Max tokens per chunk (e.g., 8191)"},
      "endpoint":   {"type": "string",  "description": "Custom API endpoint URL"},
      "default":    {"type": "boolean", "default": false, "description": "Set as default service"}
    },
    "required": ["name", "format", "model", "dimensions", "max-tokens"]
  })

  SERVICE_DELETE_SCHEMA = %({
    "type": "object",
    "positional": ["name"],
    "properties": {
      "name":  {"type": "string",  "description": "Service name to delete"},
      "force": {"type": "boolean", "default": false, "description": "Delete even if service has embeddings"}
    },
    "required": ["name"]
  })
end
