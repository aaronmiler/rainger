require "active_support/core_ext/object/blank"

module Rainger
  class Loop
    # No caller-supplied max_iterations can exceed this — a runaway loop is
    # bounded by construction, not by every call site remembering a sane cap.
    HARD_CAP = 10

    class Hooks
      def initialize
        @on_assistant_message = ->(_msg) {}
        @on_tool_result = ->(_msg) {}
      end

      def on_assistant_message(&block)
        @on_assistant_message = block
      end

      def on_tool_result(&block)
        @on_tool_result = block
      end

      def assistant_message(msg)
        @on_assistant_message.call(msg)
      end

      def tool_result(msg)
        @on_tool_result.call(msg)
      end
    end

    def self.run(messages:, model: nil, tools: [], context: {}, max_iterations: 5,
                 nudge: nil, strip_thinking: false, on_cap: :final_answer, client: Client.new)
      hooks = Hooks.new
      yield hooks if block_given?

      new(
        messages: messages.dup, model: model, tools: tools, context: context,
        max_iterations: max_iterations, nudge: nudge, strip_thinking: strip_thinking,
        on_cap: on_cap, client: client, hooks: hooks
      ).run
    end

    def initialize(messages:, model:, tools:, context:, max_iterations:, nudge:,
                    strip_thinking:, on_cap:, client:, hooks:)
      @messages = messages
      @model = model
      @tools = tools
      @tools_by_name = tools.each_with_object({}) { |t, h| h[t.tool_name] = t }
      @context = context
      @max_iterations = [max_iterations, HARD_CAP].min
      @nudge = nudge
      @strip_thinking = strip_thinking
      @on_cap = on_cap
      @client = client
      @hooks = hooks
      @events = []
    end

    def run
      iteration = 0
      loop do
        iteration += 1
        return capped_result(iteration - 1) if iteration > @max_iterations

        apply_nudge(iteration)

        message = request_message
        @messages << message
        @hooks.assistant_message(message)

        tool_calls = message["tool_calls"]
        return build_result(message["content"], iteration, capped: false) if tool_calls.blank?

        tool_calls.each { |call| handle_tool_call(call) }
      end
    rescue LoopHalted => e
      build_result(e.content, iteration, capped: false)
    end

    private

    def apply_nudge(iteration)
      return unless @nudge && iteration == @nudge[:at]

      @messages << { role: "user", content: @nudge[:content] }
    end

    def request_message
      response = @client.chat(@messages, model: @model, tools: @tools.map(&:definition).presence)
      response.dig("choices", 0, "message")
    end

    def handle_tool_call(call)
      tool_name = call.dig("function", "name")
      tool_class = @tools_by_name[tool_name]

      result =
        if tool_class
          tool_class.dispatch(call.dig("function", "arguments"), context: @context)
        else
          { content: { error: "Unknown tool: #{tool_name}" }.to_json, events: [] }
        end

      @events.concat(result[:events])

      tool_message = { role: "tool", tool_call_id: call["id"], content: result[:content] }
      @messages << tool_message
      @hooks.tool_result(tool_message)
    end

    # Default (Draft/Delta): one more call without tools, forcing a final
    # answer. `on_cap: :bail` skips that call and returns nil content instead.
    def capped_result(iterations)
      return build_result(nil, iterations, capped: true) if @on_cap == :bail

      @messages << { role: "user", content: "Please provide your final answer now, without using any more tools." }
      response = @client.chat(@messages, model: @model)
      message = response.dig("choices", 0, "message")
      @messages << message
      @hooks.assistant_message(message)
      build_result(message["content"], iterations + 1, capped: true)
    end

    def build_result(content, iterations, capped:)
      Result.new(
        content: finalize_content(content),
        events: group_events,
        messages: @messages,
        iterations: iterations,
        capped: capped
      )
    end

    def finalize_content(content)
      return content unless @strip_thinking && content.is_a?(String)

      content.gsub(%r{<think(?:ing)?>.*?</think(?:ing)?>}mi, "").strip
    end

    def group_events
      @events.group_by { |e| e[:kind] }.transform_values { |list| list.map { |e| e[:payload] } }
    end
  end
end
