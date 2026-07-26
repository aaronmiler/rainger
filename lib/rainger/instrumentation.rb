require "active_support/notifications"

module Rainger
  # Thin wrapper over AS::Notifications so callers get `rainger.chat` /
  # `rainger.embed` events carrying model, duration, and usage token counts
  # without hand-rolling instrumentation at every call site.
  module Instrumentation
    module_function

    def instrument(event, payload = {})
      ActiveSupport::Notifications.instrument("rainger.#{event}", payload) { |inner_payload| yield(inner_payload) }
    end
  end
end
