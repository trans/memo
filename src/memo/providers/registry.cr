module Memo
  module Providers
    # Provider factory
    #
    # Creates provider instances from format names.
    # Formats represent API protocols (e.g., "openai" format works with
    # OpenAI, Azure OpenAI, and any OpenAI-compatible API).
    #
    # ## Usage
    #
    # ```
    # provider = Memo::Providers::Registry.create(
    #   format: "openai",
    #   api_key: "sk-...",
    #   model: "text-embedding-3-small",
    #   base_url: "https://custom.api.com/v1"  # optional
    # )
    # ```
    module Registry
      # Create a provider instance
      #
      # Returns nil if format is not supported.
      def self.create(
        format : String,
        api_key : String? = nil,
        model : String = "",
        base_url : String? = nil
      ) : Providers::Base?
        case format
        when "openai"
          raise ArgumentError.new("api_key required for openai format") unless api_key
          final_base_url = base_url || Providers::OpenAI::DEFAULT_BASE_URL
          Providers::OpenAI.new(api_key, model, final_base_url)
        when "voyage"
          raise ArgumentError.new("api_key required for voyage format") unless api_key
          final_base_url = base_url || Providers::Voyage::DEFAULT_BASE_URL
          Providers::Voyage.new(api_key, model, final_base_url)
        when "mock"
          Providers::Mock.new
        else
          nil
        end
      end
    end
  end
end
