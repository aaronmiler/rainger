require "spec_helper"

# Runs Loop against a real Client (only Net::HTTP is stubbed, via WebMock) so a
# real Client#chat(tools:) call is exercised — a double can't catch a mismatch
# between what Loop passes and what Client expects.
RSpec.describe "Loop + real Client integration" do
  it "runs a tool-calling loop end to end without double-mapping tool definitions" do
    tool_call = { id: "call_1", function: { name: "echo", arguments: { text: "hi" }.to_json } }

    stub_request(:post, "http://litellm.test/chat/completions")
      .with { |req| JSON.parse(req.body)["tools"].present? }
      .to_return(
        status: 200,
        body: { choices: [{ message: { role: "assistant", tool_calls: [tool_call] } }] }.to_json
      ).times(1).then
      .to_return(
        status: 200,
        body: { choices: [{ message: { role: "assistant", content: "done" } }] }.to_json
      )

    result = Rainger::Loop.run(
      messages: [{ role: "user", content: "hi" }], model: :local, tools: [EchoTool]
    )

    expect(result.content).to eq("done")
  end
end
