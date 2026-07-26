module Rainger
  class Error < StandardError; end

  # Raised when the connection to the LiteLLM proxy itself fails (timeout, refused, DNS).
  class ConnectionError < Error; end

  # Raised on a non-2xx response. Carries the status and a truncated body so logs
  # stay readable without a wall of text.
  class APIError < Error
    attr_reader :status, :body

    def initialize(status:, body:)
      @status = status
      @body = body.to_s.byteslice(0, 2000)
      super("LiteLLM request failed (#{status}): #{@body}")
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
