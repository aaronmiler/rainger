require_relative "lib/rainger/version"

Gem::Specification.new do |spec|
  spec.name        = "rainger"
  spec.version     = Rainger::VERSION
  spec.authors     = ["Aaron Miler"]
  spec.summary     = "Shared LLM client, tool DSL, and agent loop for OpenAI-compatible Rails apps"
  spec.files       = Dir["lib/**/*"]
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 3.1"

  spec.add_dependency "activesupport", ">= 6.0"

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "webmock", "~> 3.26"
end
