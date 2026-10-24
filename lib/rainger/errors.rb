module Rainger
  class Error < StandardError; end

  # Raised when the connection to the proxy itself fails (timeout, refused, DNS).
  class ConnectionError < Error; end

  # Raised on a non-2xx response. Carries the status and a truncated body so logs
  # stay readable without a wall of text. `error_type` is the proxy's top-level
  # `type` field when present (Bifrost: "budget_exceeded", "rate_limited",
  # "model_blocked", ...), nil otherwise.
  class APIError < Error
    attr_reader :status, :body, :error_type

    def initialize(status:, body:)
      @status = status
      @error_type = self.class.parse_error_type(body)
      @body = body.to_s.byteslice(0, 2000)
      super("LLM request failed (#{status}): #{@body}")
    end

    def self.parse_error_type(body)
      parsed = JSON.parse(body.to_s)
      parsed["type"] if parsed.is_a?(Hash) && parsed["type"].is_a?(String)
    rescue JSON::ParserError
      nil
    end
  end

  class RateLimited < APIError; end
  class BudgetExceeded < APIError; end

  # Raised by Tool#halt! to abort a Loop run early with a final answer.
  class LoopHalted < Error
    attr_reader :content

    def initialize(content)
      @content = content
      super("Loop halted: #{content}")
    end
  end
end
