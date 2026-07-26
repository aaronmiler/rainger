require "rainger/version"
require "rainger/errors"
require "rainger/instrumentation"
require "rainger/client"
require "rainger/tool"
require "rainger/result"
require "rainger/loop"
require "rainger/prompt"

module Rainger
  class Configuration
    attr_accessor :base_url, :api_key, :app_name, :models, :app_dir,
                  :connect_timeout, :read_timeout, :prompt_path

    def initialize
      @api_key = "none"
      @models = {}
      @app_dir = "rainger"
      @connect_timeout = 10
      @read_timeout = 300
    end

    # model: a symbol resolves through `models` (string or 0-arity lambda);
    # a string passes through to LiteLLM verbatim.
    def resolve_model(model)
      return model if model.is_a?(String)

      value = models.fetch(model) { raise ArgumentError, "Unknown model alias: #{model.inspect}" }
      value.respond_to?(:call) ? value.call.to_s : value.to_s
    end
  end

  class << self
    def configure
      yield(configuration)
    end

    def configuration
      @configuration ||= Configuration.new
    end

    # Test/console convenience; not part of the app-facing API.
    def reset!
      @configuration = nil
    end

    def chat(messages, **opts)
      Client.new.chat(messages, **opts)
    end

    def embed(texts, **opts)
      Client.new.embed(texts, **opts)
    end

    def extract_json(text)
      Client.extract_json(text)
    end
  end
end
