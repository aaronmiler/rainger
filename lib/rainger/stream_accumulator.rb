module Rainger
  # Folds a sequence of OpenAI-style SSE delta chunks into one response hash
  # shaped like a non-streaming chat completion (choices/message/content,
  # tool_calls, usage) so callers can treat both code paths' return value the
  # same way once the stream ends.
  class StreamAccumulator
    def initialize
      @choices = {}
      @usage = nil
    end

    def merge!(chunk)
      @usage = chunk["usage"] if chunk["usage"].present?

      Array(chunk["choices"]).each do |choice|
        state = (@choices[choice["index"] || 0] ||= new_choice)
        delta = choice["delta"] || {}

        state[:role] = delta["role"] if delta["role"].present?
        state[:content] << delta["content"] if delta["content"]
        state[:finish_reason] = choice["finish_reason"] if choice["finish_reason"].present?

        Array(delta["tool_calls"]).each { |tool_call_delta| merge_tool_call!(state, tool_call_delta) }
      end
    end

    def to_response
      choices = @choices.sort.map do |index, state|
        message = { "role" => state[:role], "content" => state[:content] }
        message["tool_calls"] = state[:tool_calls].sort.map { |_, tc| tc } if state[:tool_calls].any?

        { "index" => index, "message" => message, "finish_reason" => state[:finish_reason] }
      end

      Rainger.indifferent({ "choices" => choices, "usage" => @usage })
    end

    private

    def new_choice
      { role: "assistant", content: +"", finish_reason: nil, tool_calls: {} }
    end

    def merge_tool_call!(state, tool_call_delta)
      index = tool_call_delta["index"] || 0
      tool_call = (state[:tool_calls][index] ||= {
        "id" => nil, "type" => "function", "function" => { "name" => "", "arguments" => +"" }
      })

      tool_call["id"] = tool_call_delta["id"] if tool_call_delta["id"].present?
      tool_call["type"] = tool_call_delta["type"] if tool_call_delta["type"].present?

      function_delta = tool_call_delta["function"] || {}
      tool_call["function"]["name"] << function_delta["name"] if function_delta["name"]
      tool_call["function"]["arguments"] << function_delta["arguments"] if function_delta["arguments"]
    end
  end
end
