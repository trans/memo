require "json"

module Memo::CLI
  # JSON Schema definitions for CLI commands
  #
  # These schemas serve as the single source of truth for:
  # - Command parameter validation
  # - Help text generation
  # - Type coercion rules

  SCHEMA_JSON = <<-JSON
  {
    "index": {
      "type": "object",
      "properties": {
        "source-type": {
          "type": "string",
          "description": "Source type identifier (e.g., article, note)"
        },
        "source-id": {
          "type": "integer",
          "description": "Unique source ID"
        },
        "text": {
          "type": "string",
          "description": "Text content to index"
        },
        "pair-id": {
          "type": "integer",
          "description": "Related source ID (optional)"
        },
        "parent-id": {
          "type": "integer",
          "description": "Parent source ID for hierarchies (optional)"
        }
      },
      "required": ["source-type", "source-id", "text"]
    },
    "search": {
      "type": "object",
      "properties": {
        "query": {
          "type": "string",
          "description": "Search query text"
        },
        "limit": {
          "type": "integer",
          "default": 10,
          "description": "Maximum number of results"
        },
        "min-score": {
          "type": "number",
          "default": 0.7,
          "description": "Minimum similarity score (0.0-1.0)"
        },
        "source-type": {
          "type": "string",
          "description": "Filter by source type"
        },
        "source-id": {
          "type": "integer",
          "description": "Filter by source ID"
        },
        "include-text": {
          "type": "boolean",
          "default": false,
          "description": "Include chunk text in results"
        }
      },
      "required": ["query"]
    },
    "delete": {
      "type": "object",
      "properties": {
        "source-id": {
          "type": "integer",
          "description": "Source ID to delete"
        },
        "source-type": {
          "type": "string",
          "description": "Filter deletion by source type"
        }
      },
      "required": ["source-id"]
    },
    "stats": {
      "type": "object",
      "properties": {}
    },
    "service": {
      "type": "object",
      "properties": {},
      "subcommands": {
        "list": {
          "type": "object",
          "properties": {}
        },
        "use": {
          "type": "object",
          "properties": {
            "name": {
              "type": "string",
              "description": "Service name to set as default (positional arg allowed)"
            }
          },
          "required": ["name"]
        },
        "create": {
          "type": "object",
          "properties": {
            "name": {
              "type": "string",
              "description": "Unique service name"
            },
            "format": {
              "type": "string",
              "description": "Provider format (openai, voyage)"
            },
            "model": {
              "type": "string",
              "description": "Model name (e.g., text-embedding-3-small)"
            },
            "dimensions": {
              "type": "integer",
              "description": "Embedding dimensions (e.g., 1536)"
            },
            "max-tokens": {
              "type": "integer",
              "description": "Max tokens per chunk (e.g., 8191)"
            },
            "endpoint": {
              "type": "string",
              "description": "Custom API endpoint URL"
            },
            "default": {
              "type": "boolean",
              "default": false,
              "description": "Set as default service"
            }
          },
          "required": ["name", "format", "model", "dimensions", "max-tokens"]
        },
        "delete": {
          "type": "object",
          "properties": {
            "name": {
              "type": "string",
              "description": "Service name to delete (positional arg allowed)"
            },
            "force": {
              "type": "boolean",
              "default": false,
              "description": "Delete even if service has embeddings"
            }
          },
          "required": ["name"]
        }
      }
    }
  }
  JSON

  SCHEMAS = JSON.parse(SCHEMA_JSON).as_h

  # Get list of available commands
  def self.commands : Array(String)
    SCHEMAS.keys
  end

  # Get schema for a command
  def self.schema(command : String) : JSON::Any?
    SCHEMAS[command]?
  end

  # Get subcommands for a command
  def self.subcommands(command : String) : Array(String)
    if schema = SCHEMAS[command]?
      if subs = schema["subcommands"]?
        return subs.as_h.keys
      end
    end
    [] of String
  end

  # Get schema for a subcommand
  def self.subcommand_schema(command : String, subcommand : String) : JSON::Any?
    if schema = SCHEMAS[command]?
      if subs = schema["subcommands"]?
        return subs[subcommand]?
      end
    end
    nil
  end
end
