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
    #
    # stream: true requires a block. The block receives each parsed delta chunk as
    # it arrives; the method itself still returns the fully-assembled response hash
    # (same shape as the non-streaming path) once the stream ends.
    def chat(messages, model: nil, tools: nil, temperature: nil, max_tokens: nil, stream: false, &block)
      resolved_model = @config.resolve_model(model)
      body = { model: resolved_model, messages: messages }
      body[:tools] = tools.map(&:definition) if tools.present?
      body[:temperature] = temperature unless temperature.nil?
      body[:max_tokens] = max_tokens unless max_tokens.nil?

      if stream
        raise ArgumentError, "stream: true requires a block to receive chunks" unless block

        body[:stream] = true
        Instrumentation.instrument("chat", model: resolved_model) do |payload|
          response = post_stream("chat/completions", body, &block)
          payload[:usage] = response["usage"]
          response
        end
      else
        Instrumentation.instrument("chat", model: resolved_model) do |payload|
          response = post("chat/completions", body)
          payload[:usage] = response["usage"]
          response
        end
      end
    end

    # => Array<Array<Float>>
    def embed(texts, model: nil)
      resolved_model = @config.resolve_model(model)

      Instrumentation.instrument("embed", model: resolved_model) do |payload|
        response = post("embeddings", model: resolved_model, input: Array(texts))
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
      uri = http_uri(path)
      http = build_http(uri)
      request = build_request(uri, body)

      response =
        begin
          http.request(request)
        rescue Timeout::Error, Errno::ECONNREFUSED, SocketError => e
          raise ConnectionError, e.message
        end

      raise_api_error(response) unless response.is_a?(Net::HTTPSuccess)

      Rainger.parse_json(response.body)
    end

    # Streams the SSE response, yielding each parsed delta chunk to the caller's
    # block as it arrives, and returns the deltas folded into one response hash
    # shaped like the non-streaming path's return value.
    def post_stream(path, body)
      uri = http_uri(path)
      http = build_http(uri)
      request = build_request(uri, body)
      accumulator = StreamAccumulator.new
      buffer = +""

      begin
        http.request(request) do |response|
          raise_api_error(response) unless response.is_a?(Net::HTTPSuccess)

          response.read_body do |chunk|
            buffer << chunk
            while (boundary = buffer.index("\n\n"))
              event = buffer.slice!(0..boundary + 1)
              parsed = parse_sse_event(event)
              next if parsed.nil?

              accumulator.merge!(parsed)
              yield parsed
            end
          end
        end
      rescue Timeout::Error, Errno::ECONNREFUSED, SocketError => e
        raise ConnectionError, e.message
      end

      accumulator.to_response
    end

    # A single SSE frame is one or more "field: value" lines separated by "\n\n".
    # We only care about "data: ..."; "[DONE]" marks the end of the stream and
    # every other field (event:, id:, comments) is not something LiteLLM sends here.
    def parse_sse_event(event)
      data_lines = event.each_line.select { |line| line.start_with?("data:") }
      return nil if data_lines.empty?

      data = data_lines.map { |line| line.sub(/\Adata:\s?/, "") }.join.strip
      return nil if data.empty? || data == "[DONE]"

      Rainger.parse_json(data)
    end

    def build_http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @config.connect_timeout
      http.read_timeout = @config.read_timeout
      http
    end

    # URI.join treats a leading-slash path as absolute, silently discarding any
    # path component of base_url (e.g. "/v1"). Normalize base_url to end with
    # "/" and join a relative path so any base_url sub-path is preserved.
    def http_uri(path)
      base = @config.base_url.end_with?("/") ? @config.base_url : "#{@config.base_url}/"
      URI.join(base, path)
    end

    def build_request(uri, body)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{@config.api_key}"
      request["User-Agent"] = "rainger/#{VERSION} (#{@config.app_name})"
      request.body = body.to_json
      request
    end

    def raise_api_error(response)
      status = response.code.to_i
      body = response.body

      klass =
        if body.to_s.match?(/budget/i)
          BudgetExceeded
        elsif status == 429
          RateLimited
        else
          APIError
        end

      raise klass.new(status: status, body: body)
    end
  end
end
