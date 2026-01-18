module Memo
  module Providers
    # Model configuration for a provider
    struct ModelConfig
      getter dimensions : Int32
      getter max_tokens : Int32

      def initialize(@dimensions : Int32, @max_tokens : Int32)
      end
    end

    # Provider configuration and metadata
    struct ProviderConfig
      getter name : String
      getter default_model : String
      getter models : Hash(String, ModelConfig)

      def initialize(@name : String, @default_model : String, @models : Hash(String, ModelConfig))
      end

      # Get model config, returns nil if not found
      def model(name : String) : ModelConfig?
        @models[name]?
      end

      # Get dimensions for a model (uses default if model not specified)
      def dimensions(model : String? = nil) : Int32?
        m = model || @default_model
        @models[m]?.try(&.dimensions)
      end

      # Get max_tokens for a model (uses default if model not specified)
      def max_tokens(model : String? = nil) : Int32?
        m = model || @default_model
        @models[m]?.try(&.max_tokens)
      end
    end

    # Factory function type for creating provider instances
    # Takes (api_key, model) and returns a provider instance
    alias ProviderFactory = Proc(String?, String?, Providers::Base)

    # Registry for dynamic provider management
    #
    # Allows registration of custom embedding providers at runtime.
    # Built-in providers (openai, mock) are registered automatically.
    #
    # ## Usage
    #
    # ```
    # # Register a custom provider
    # Memo::Providers::Registry.register(
    #   name: "custom",
    #   factory: ->(api_key : String?, model : String?) {
    #     CustomProvider.new(api_key.not_nil!, model || "default")
    #   },
    #   config: Memo::Providers::ProviderConfig.new(
    #     name: "custom",
    #     default_model: "custom-model-v1",
    #     models: {
    #       "custom-model-v1" => Memo::Providers::ModelConfig.new(768, 4096)
    #     }
    #   )
    # )
    #
    # # List available providers
    # providers = Memo::Providers::Registry.list
    #
    # # Check if provider exists
    # if Memo::Providers::Registry.registered?("custom")
    #   config = Memo::Providers::Registry.config("custom")
    # end
    # ```
    module Registry
      @@providers = {} of String => {ProviderFactory, ProviderConfig}

      # Register a provider
      #
      # - name: Unique provider identifier (e.g., "openai", "cohere")
      # - factory: Function to create provider instances
      # - config: Provider metadata including models and their configurations
      def self.register(
        name : String,
        factory : ProviderFactory,
        config : ProviderConfig
      )
        @@providers[name] = {factory, config}
      end

      # Unregister a provider
      #
      # Returns true if provider was removed, false if it didn't exist
      def self.unregister(name : String) : Bool
        !!@@providers.delete(name)
      end

      # Check if a provider is registered
      def self.registered?(name : String) : Bool
        @@providers.has_key?(name)
      end

      # Get provider factory by name
      def self.factory(name : String) : ProviderFactory?
        @@providers[name]?.try(&.first)
      end

      # Get provider configuration by name
      def self.config(name : String) : ProviderConfig?
        @@providers[name]?.try(&.last)
      end

      # List all registered provider names
      def self.list : Array(String)
        @@providers.keys
      end

      # List all provider configurations
      def self.configs : Array(ProviderConfig)
        @@providers.values.map(&.last)
      end

      # Create a provider instance
      #
      # Returns nil if provider is not registered
      def self.create(name : String, api_key : String? = nil, model : String? = nil) : Providers::Base?
        factory(name).try(&.call(api_key, model))
      end

      # Get default model for a provider
      def self.default_model(name : String) : String?
        config(name).try(&.default_model)
      end

      # Get dimensions for a provider/model combination
      def self.dimensions(provider : String, model : String? = nil) : Int32?
        config(provider).try(&.dimensions(model))
      end

      # Get max_tokens for a provider/model combination
      def self.max_tokens(provider : String, model : String? = nil) : Int32?
        config(provider).try(&.max_tokens(model))
      end

      # Clear all registered providers (mainly for testing)
      def self.clear
        @@providers.clear
      end

      # Register built-in providers
      #
      # Called automatically when the module is loaded.
      # Can be called again to restore defaults after clear.
      def self.register_defaults
        # OpenAI provider
        register(
          name: "openai",
          factory: ->(api_key : String?, model : String?) {
            raise ArgumentError.new("api_key required for openai provider") unless api_key
            Providers::OpenAI.new(api_key, model || "text-embedding-3-small").as(Providers::Base)
          },
          config: ProviderConfig.new(
            name: "openai",
            default_model: "text-embedding-3-small",
            models: {
              "text-embedding-3-small" => ModelConfig.new(dimensions: 1536, max_tokens: 8191),
              "text-embedding-3-large" => ModelConfig.new(dimensions: 3072, max_tokens: 8191),
            }
          )
        )

        # Mock provider (for testing)
        register(
          name: "mock",
          factory: ->(api_key : String?, model : String?) {
            Providers::Mock.new.as(Providers::Base)
          },
          config: ProviderConfig.new(
            name: "mock",
            default_model: "mock-8d",
            models: {
              "mock-8d" => ModelConfig.new(dimensions: 8, max_tokens: 100),
            }
          )
        )
      end
    end

    # Auto-register built-in providers on load
    Registry.register_defaults
  end
end
