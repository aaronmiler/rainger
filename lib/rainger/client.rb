require "net/http"
require "json"
require "uri"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/hash/indifferent_access"

module Rainger
  class Client
    def initialize(config: Rainger.configuration)
      @config = config
    end

    # => parsed response hash (full body — callers keep digging choices/0/message, as today)
    def chat(messages, model: nil, tools: nil, temperature: nil, max_tokens: nil)
      resolved_model = @config.resolve_model(model)
      body = { model: resolved_model, messages: messages }
      body[:tools] = tools.map(&:definition) if tools.present?
      body[:temperature] = temperature unless temperature.nil?
      body[:max_tokens] = max_tokens unless max_tokens.nil?

      Instrumentation.instrument("chat", model: resolved_model) do |payload|
        response = post("/chat/completions", body)
        payload[:usage] = response["usage"]
        response
      end
    end

    # => Array<Array<Float>>
    def embed(texts, model: nil)
      resolved_model = @config.resolve_model(model)

      Instrumentation.instrument("embed", model: resolved_model) do |payload|
        response = post("/embeddings", model: resolved_model, input: Array(texts))
        payload[:usage] = response["usage"]
        response["data"].map { |row| row["embedding"] }
      end
    end

    # Tolerant JSON pull: strips <think>/<thinking> blocks, prefers a fenced
    # ```json block, falls back to the outermost {...} / [...]. Returns nil
    # rather than raising — callers decide how to handle a model that didn't
    # produce parseable JSON.
    def self.extract_json(text)
      return nil if text.nil?

      cleaned = text.to_s.gsub(%r{<think(?:ing)?>.*?</think(?:ing)?>}mi, "")

      if (match = cleaned.match(/```(?:json)?\s*(\{.*\}|\[.*\])\s*```/mi))
        parsed = safe_parse(match[1])
        return parsed unless parsed.nil?
      end

      if (match = cleaned.match(/(\{.*\}|\[.*\])/mi))
        return safe_parse(match[1])
      end

      nil
    end

    def self.safe_parse(str)
      Rainger.parse_json(str)
    rescue JSON::ParserError
      nil
    end
    private_class_method :safe_parse

    private

    def post(path, body)
      uri = URI.join(@config.base_url, path)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @config.connect_timeout
      http.read_timeout = @config.read_timeout

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{@config.api_key}"
      request["User-Agent"] = "rainger/#{VERSION} (#{@config.app_name})"
      request.body = body.to_json

      response =
        begin
          http.request(request)
        rescue Timeout::Error, Errno::ECONNREFUSED, SocketError => e
          raise ConnectionError, e.message
        end

      raise_api_error(response) unless response.is_a?(Net::HTTPSuccess)

      Rainger.parse_json(response.body)
    end

    def raise_api_error(response)
      status = response.code.to_i
      body = response.body

      klass =
        if status == 429
          RateLimited
        elsif body.to_s.match?(/budget/i)
          BudgetExceeded
        else
          APIError
        end

      raise klass.new(status: status, body: body)
    end
  end
end
