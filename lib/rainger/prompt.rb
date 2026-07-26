require "erb"
require "pathname"

module Rainger
  # ERB file prompts: Rainger::Prompt.render("query_runner", date: ..., persona: ...)
  # reads app/rainger/prompts/query_runner.md.erb by default (configurable via
  # Rainger.configuration.prompt_path).
  class Prompt
    def self.render(name, **locals)
      erb = ERB.new(File.read(template_path(name)), trim_mode: "-")
      Binding.new(locals).render(erb)
    end

    def self.template_path(name)
      Pathname.new(base_path).join("#{name}.md.erb")
    end

    def self.base_path
      Rainger.configuration.prompt_path || default_path
    end

    def self.default_path
      unless defined?(Rails)
        raise Error, "No prompt_path configured and Rails is not defined; " \
                      "set Rainger.configuration.prompt_path"
      end

      Rails.root.join("app", Rainger.configuration.app_dir, "prompts")
    end

    # Isolated binding so locals are exposed as methods without leaking
    # Prompt's own state into the template.
    class Binding
      def initialize(locals)
        locals.each { |key, value| define_singleton_method(key) { value } }
      end

      def render(erb)
        erb.result(binding)
      end
    end
  end
end
