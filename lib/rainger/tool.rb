require "json"
require "active_support/core_ext/string/inflections"

module Rainger
  # Subclass this, declare params, define #call. The class *is* the JSON
  # schema generator and the dispatcher — .definition is what you hand to
  # LiteLLM, .dispatch is what the Loop calls when the model picks this tool.
  class Tool
    class << self
      def tool_name(value = nil)
        @tool_name = value.to_s if value
        @tool_name ||= name.split("::").last.underscore.sub(/_tool\z/, "")
      end

      def description(value = nil)
        @description = value if value
        @description
      end

      def params
        @params ||= []
      end

      def param(param_name, type, param_description, required: false, enum: nil, items: nil)
        params << {
          name: param_name,
          type: type,
          description: param_description,
          required: required,
          enum: enum,
          items: items
        }
      end

      # Declares a reader backed by a value passed in the Loop's `context:`
      # hash at run time (e.g. `context :default_week_of`).
      def context(*names)
        context_attrs.concat(names)
        attr_reader(*names)
      end

      def context_attrs
        @context_attrs ||= []
      end

      # Escape hatch for schemas the declarative `param` DSL can't express.
      def schema(&block)
        @custom_schema = block
      end

      def definition
        if @custom_schema && params.any?
          raise ArgumentError, "#{self} declares both `param` and a custom `schema` block — use one or the other"
        end

        @definition ||= {
          type: "function",
          function: {
            name: tool_name,
            description: description,
            parameters: @custom_schema ? @custom_schema.call : generated_schema
          }
        }.freeze
      end

      def generated_schema
        {
          type: "object",
          properties: params.each_with_object({}) { |p, h| h[p[:name]] = property_schema(p) },
          required: params.select { |p| p[:required] }.map { |p| p[:name].to_s }
        }
      end

      def property_schema(param)
        schema = { type: param[:type].to_s, description: param[:description] }
        schema[:enum] = param[:enum] if param[:enum]
        if param[:items]
          schema[:items] = param[:items].is_a?(Hash) ? param[:items] : { type: param[:items].to_s }
        end
        schema
      end

      # Parses the model's JSON args, drops unknown keys (a hallucinated
      # argument can't crash dispatch), instantiates with context, and
      # rescues #call errors into a tool-result message instead of raising.
      def dispatch(raw_args, context: {})
        args = parse_args(raw_args)
        known = params.map { |p| p[:name].to_s }
        kwargs = args.slice(*known).transform_keys(&:to_sym)

        instance = new(context)
        result = instance.call(**kwargs)
        { content: stringify(result), events: instance.events }
      rescue LoopHalted
        raise
      rescue StandardError => e
        { content: { error: clean_message(e) }.to_json, events: [] }
      end

      private

      def parse_args(raw_args)
        return raw_args if raw_args.is_a?(Hash)

        JSON.parse(raw_args.to_s)
      rescue JSON::ParserError
        {}
      end

      def stringify(result)
        result.is_a?(String) ? result : result.to_json
      end

      def clean_message(error)
        if defined?(ActiveRecord::RecordNotFound) && error.is_a?(ActiveRecord::RecordNotFound)
          "Not found."
        elsif defined?(ActiveRecord::RecordInvalid) && error.is_a?(ActiveRecord::RecordInvalid)
          error.record.errors.full_messages.join(", ")
        else
          error.message
        end
      end
    end

    attr_reader :events

    def initialize(context = {})
      @context = context
      @events = []
      self.class.context_attrs.each do |attr_name|
        instance_variable_set("@#{attr_name}", context[attr_name])
      end
    end

    # Out-of-band channel for anything alongside the return value (sources,
    # side effects). Collected per-call and grouped by kind on Result#events.
    def emit(kind, payload = {})
      events << { kind: kind, payload: payload }
    end

    # Aborts the Loop early with `content` as the final answer, bypassing
    # any remaining iterations.
    def halt!(content)
      raise LoopHalted, content
    end
  end
end
