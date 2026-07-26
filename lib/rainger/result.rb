module Rainger
  class Result
    attr_reader :content, :events, :messages, :iterations

    def initialize(content:, events:, messages:, iterations:, capped:)
      @content = content
      @events = events
      @messages = messages
      @iterations = iterations
      @capped = capped
    end

    def capped?
      @capped
    end
  end
end
