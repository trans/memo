module Memo
  module Providers
    # Model configuration defaults for known models
    struct ModelDefaults
      getter dimensions : Int32
      getter max_tokens : Int32

      def initialize(@dimensions : Int32, @max_tokens : Int32)
      end
    end

    # API format registry
    #
    # Maps format names to provider implementations and known model defaults.
    # Formats represent API protocols (e.g., "openai" format works with
    # OpenAI, Azure OpenAI, and any OpenAI-compatible API).
    #
    # ## Usage
    #
    # ```
    # # Create a provider instance
    # provider = Memo::Providers::Registry.create(
    #   format: "openai",
    #   api_key: "sk-...",
    #   model: "text-embedding-3-small",
    #   base_url: "https://custom.api.com/v1"  # optional
    # )
    #
    # # Get model defaults
    # defaults = Memo::Providers::Registry.model_defaults("openai", "text-embedding-3-small")
    # defaults.dimensions  # => 1536
    # defaults.max_tokens  # => 8191
    #
    # # List available formats
    # formats = Memo::Providers::Registry.formats  # => ["openai", "mock"]
    # ```
    module Registry
      # Known model defaults by format and model name
      MODELS = {
        "openai" => {
          "text-embedding-3-small" => ModelDefaults.new(dimensions: 1536, max_tokens: 8191),
          "text-embedding-3-large" => ModelDefaults.new(dimensions: 3072, max_tokens: 8191),
          "text-embedding-ada-002" => ModelDefaults.new(dimensions: 1536, max_tokens: 8191),
        },
        "mock" => {
          "mock-8d" => ModelDefaults.new(dimensions: 8, max_tokens: 100),
        },
      }

      # Default model for each format
      DEFAULT_MODELS = {
        "openai" => "text-embedding-3-small",
        "mock"   => "mock-8d",
      }

      # List available API formats
      def self.formats : Array(String)
        ["openai", "mock"]
      end

      # Check if a format is supported
      def self.format?(name : String) : Bool
        formats.includes?(name)
      end

      # Get default model for a format
      def self.default_model(format : String) : String?
        DEFAULT_MODELS[format]?
      end

      # Get model defaults (dimensions, max_tokens)
      #
      # Returns nil if format or model is unknown.
      def self.model_defaults(format : String, model : String) : ModelDefaults?
        MODELS[format]?.try(&.[model]?)
      end

      # Get dimensions for a format/model combination
      def self.dimensions(format : String, model : String) : Int32?
        model_defaults(format, model).try(&.dimensions)
      end

      # Get max_tokens for a format/model combination
      def self.max_tokens(format : String, model : String) : Int32?
        model_defaults(format, model).try(&.max_tokens)
      end

      # Create a provider instance
      #
      # Returns nil if format is not supported.
      def self.create(
        format : String,
        api_key : String? = nil,
        model : String? = nil,
        base_url : String? = nil
      ) : Providers::Base?
        case format
        when "openai"
          raise ArgumentError.new("api_key required for openai format") unless api_key
          final_model = model || DEFAULT_MODELS["openai"]
          final_base_url = base_url || Providers::OpenAI::DEFAULT_BASE_URL
          Providers::OpenAI.new(api_key, final_model, final_base_url)
        when "mock"
          Providers::Mock.new
        else
          nil
        end
      end
    end
  end
end
