require "spec_helper"
require "tmpdir"

RSpec.describe Rainger::Prompt do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  before do
    Rainger.configuration.prompt_path = @dir
    File.write(File.join(@dir, "greeting.md.erb"), "Hello, <%= name %>!")
  end

  it "renders an ERB template with locals in scope" do
    expect(described_class.render("greeting", name: "Aaron")).to eq("Hello, Aaron!")
  end

  it "raises a clear error when neither prompt_path nor Rails is available" do
    Rainger.configuration.prompt_path = nil

    expect { described_class.render("greeting", name: "Aaron") }.to raise_error(Rainger::Error, /Rails is not defined/)
  end
end
