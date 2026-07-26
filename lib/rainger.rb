require "json"
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
                  :connect_timeout, :read_timeout, :prompt_path, :default_model

    def initialize
      @api_key = "none"
      @models = {}
      @app_dir = "rainger"
      @connect_timeout = 10
      @read_timeout = 300
    end

    # model: nil falls back to `default_model` (string or 0-arity lambda); a
    # symbol resolves through `models` (string or 0-arity lambda); a string
    # passes through to LiteLLM verbatim.
    def resolve_model(model = nil)
      model ||= default_model
      raise ArgumentError, "No model given and no default_model configured" if model.nil?
      return model.call.to_s if model.respond_to?(:call)
      return model.to_s if model.is_a?(String)

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

    # Hash#with_indifferent_access already deep-converts nested hashes (including
    # those inside arrays); a top-level Array just needs that applied per element.
    # Shared so every hash flowing through the gem (parsed API responses, hand-built
    # tool/nudge messages) uses the same string/symbol-agnostic access.
    def indifferent(value)
      case value
      when Hash then value.with_indifferent_access
      when Array then value.map { |v| indifferent(v) }
      else value
      end
    end

    # JSON.parse + indifferent, for the two spots (raw API responses, extract_json's
    # fenced/braced matches) that always pair the two.
    def parse_json(str)
      indifferent(JSON.parse(str))
    end
  end
end
