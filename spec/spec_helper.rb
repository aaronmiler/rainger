require "rainger"
require "webmock/rspec"

WebMock.disable_net_connect!(allow_localhost: true)

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }

  config.before do
    Rainger.reset!
    Rainger.configure do |c|
      c.base_url = "http://litellm.test"
      c.api_key = "test-key"
      c.app_name = "spec"
      c.models = { local: "local-model", cloud: -> { "cloud-model" } }
    end
  end
end
