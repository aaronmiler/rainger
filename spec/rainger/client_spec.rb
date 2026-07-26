require "spec_helper"

RSpec.describe Rainger::Client do
  subject(:client) { described_class.new }

  describe "#chat" do
    it "resolves a model alias and posts to /chat/completions" do
      stub = stub_request(:post, "http://litellm.test/chat/completions")
        .with(body: hash_including("model" => "local-model"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { choices: [{ message: { role: "assistant", content: "hi" } }], usage: { total_tokens: 5 } }.to_json
        )

      response = client.chat([{ role: "user", content: "hello" }], model: :local)

      expect(stub).to have_been_requested
      expect(response.dig("choices", 0, "message", "content")).to eq("hi")
    end

    it "falls back to default_model when model: is omitted" do
      Rainger.configuration.default_model = -> { "default-model" }
      stub = stub_request(:post, "http://litellm.test/chat/completions")
        .with(body: hash_including("model" => "default-model"))
        .to_return(status: 200, body: { choices: [] }.to_json)

      client.chat([{ role: "user", content: "hi" }])

      expect(stub).to have_been_requested
    end

    it "raises ArgumentError when model: is omitted and no default_model is configured" do
      expect { client.chat([{ role: "user", content: "hi" }]) }.to raise_error(ArgumentError, /No model given/)
    end

    it "passes a literal model string through verbatim" do
      stub = stub_request(:post, "http://litellm.test/chat/completions")
        .with(body: hash_including("model" => "literal-model"))
        .to_return(status: 200, body: { choices: [] }.to_json)

      client.chat([{ role: "user", content: "hi" }], model: "literal-model")

      expect(stub).to have_been_requested
    end

    it "raises RateLimited on a 429" do
      stub_request(:post, "http://litellm.test/chat/completions").to_return(status: 429, body: "slow down")

      expect { client.chat([], model: :local) }.to raise_error(Rainger::RateLimited)
    end

    it "raises BudgetExceeded when the error body mentions budget" do
      stub_request(:post, "http://litellm.test/chat/completions")
        .to_return(status: 403, body: "Exceeded budget for this key")

      expect { client.chat([], model: :local) }.to raise_error(Rainger::BudgetExceeded)
    end

    it "raises a plain APIError otherwise" do
      stub_request(:post, "http://litellm.test/chat/completions").to_return(status: 500, body: "boom")

      expect { client.chat([], model: :local) }.to raise_error(Rainger::APIError)
    end

    it "wraps connection failures" do
      stub_request(:post, "http://litellm.test/chat/completions").to_timeout

      expect { client.chat([], model: :local) }.to raise_error(Rainger::ConnectionError)
    end
  end

  describe "#embed" do
    it "returns an array of embedding vectors" do
      stub_request(:post, "http://litellm.test/embeddings")
        .to_return(status: 200, body: { data: [{ embedding: [0.1, 0.2] }] }.to_json)

      expect(client.embed(["hi"], model: :local)).to eq([[0.1, 0.2]])
    end
  end

  describe ".extract_json" do
    it "prefers a fenced json block" do
      text = "here you go\n```json\n{\"a\": 1}\n```"
      expect(described_class.extract_json(text)).to eq({ "a" => 1 })
    end

    it "strips thinking blocks before parsing" do
      text = "<think>let me consider</think>{\"a\": 1}"
      expect(described_class.extract_json(text)).to eq({ "a" => 1 })
    end

    it "falls back to the outermost braces" do
      text = "sure, the answer is {\"a\": 1} thanks"
      expect(described_class.extract_json(text)).to eq({ "a" => 1 })
    end

    it "returns nil when nothing parses" do
      expect(described_class.extract_json("no json here")).to be_nil
    end

    it "returns a hash accessible by both string and symbol keys" do
      parsed = described_class.extract_json("{\"a\": 1}")
      expect(parsed[:a]).to eq(1)
      expect(parsed["a"]).to eq(1)
    end

    it "gives indifferent access to nested hashes, including inside arrays" do
      parsed = described_class.extract_json("{\"items\": [{\"name\": \"x\"}]}")
      expect(parsed[:items].first[:name]).to eq("x")
    end

    it "gives indifferent access to hashes inside a top-level array" do
      parsed = described_class.extract_json("[{\"a\": 1}, {\"a\": 2}]")
      expect(parsed.map { |h| h[:a] }).to eq([1, 2])
    end
  end
end
