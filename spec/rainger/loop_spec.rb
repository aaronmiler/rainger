require "spec_helper"

class EchoTool < Rainger::Tool
  tool_name "echo"
  description "Echoes the input"
  param :text, :string, "text to echo", required: true

  def call(text:)
    emit(:side_effect, echoed: text)
    "echo: #{text}"
  end
end

RSpec.describe Rainger::Loop do
  def message(role:, content: nil, tool_calls: nil)
    msg = { "role" => role }
    msg["content"] = content if content
    msg["tool_calls"] = tool_calls if tool_calls
    msg
  end

  it "returns the final content when the model answers without tools" do
    client = instance_double(Rainger::Client)
    allow(client).to receive(:chat)
      .and_return({ "choices" => [{ "message" => message(role: "assistant", content: "the answer") }] })

    result = described_class.run(messages: [{ role: "user", content: "hi" }], model: :local, client: client)

    expect(result.content).to eq("the answer")
    expect(result.iterations).to eq(1)
    expect(result).not_to be_capped
  end

  it "dispatches tool calls, feeds results back, and collects emitted events" do
    client = instance_double(Rainger::Client)
    tool_call = { "id" => "call_1", "function" => { "name" => "echo", "arguments" => { "text" => "hi" }.to_json } }

    allow(client).to receive(:chat).and_return(
      { "choices" => [{ "message" => message(role: "assistant", tool_calls: [tool_call]) }] },
      { "choices" => [{ "message" => message(role: "assistant", content: "done") }] }
    )

    result = described_class.run(
      messages: [{ role: "user", content: "hi" }], model: :local, tools: [EchoTool], client: client
    )

    expect(result.content).to eq("done")
    expect(result.events).to eq({ side_effect: [{ echoed: "hi" }] })
    expect(result.messages.map { |m| m["role"] || m[:role] }).to include("tool")
  end

  it "clamps max_iterations to HARD_CAP" do
    client = instance_double(Rainger::Client)
    tool_call = { "id" => "call_1", "function" => { "name" => "echo", "arguments" => { "text" => "hi" }.to_json } }
    allow(client).to receive(:chat).and_return(
      { "choices" => [{ "message" => message(role: "assistant", tool_calls: [tool_call]) }] }
    )

    loop_runner = described_class.new(
      messages: [{ role: "user", content: "hi" }], model: :local, tools: [EchoTool], context: {},
      max_iterations: 999, nudge: nil, strip_thinking: false, on_cap: :bail, client: client,
      hooks: described_class::Hooks.new
    )

    expect(loop_runner.instance_variable_get(:@max_iterations)).to eq(described_class::HARD_CAP)
  end

  it "forces a final answer at the cap by default" do
    client = instance_double(Rainger::Client)
    tool_call = { "id" => "call_1", "function" => { "name" => "echo", "arguments" => { "text" => "hi" }.to_json } }

    allow(client).to receive(:chat).and_return(
      { "choices" => [{ "message" => message(role: "assistant", tool_calls: [tool_call]) }] },
      { "choices" => [{ "message" => message(role: "assistant", content: "forced answer") }] }
    )

    result = described_class.run(
      messages: [{ role: "user", content: "hi" }], model: :local, tools: [EchoTool],
      max_iterations: 1, client: client
    )

    expect(result).to be_capped
    expect(result.content).to eq("forced answer")
  end

  it "bails with nil content when on_cap: :bail" do
    client = instance_double(Rainger::Client)
    tool_call = { "id" => "call_1", "function" => { "name" => "echo", "arguments" => { "text" => "hi" }.to_json } }
    allow(client).to receive(:chat)
      .and_return({ "choices" => [{ "message" => message(role: "assistant", tool_calls: [tool_call]) }] })

    result = described_class.run(
      messages: [{ role: "user", content: "hi" }], model: :local, tools: [EchoTool],
      max_iterations: 1, on_cap: :bail, client: client
    )

    expect(result).to be_capped
    expect(result.content).to be_nil
  end

  it "strips <think> blocks when strip_thinking is true" do
    client = instance_double(Rainger::Client)
    allow(client).to receive(:chat).and_return(
      { "choices" => [{ "message" => message(role: "assistant", content: "<think>hmm</think>final") }] }
    )

    result = described_class.run(
      messages: [{ role: "user", content: "hi" }], model: :local, strip_thinking: true, client: client
    )

    expect(result.content).to eq("final")
  end

  it "invokes hooks for assistant messages and tool results" do
    client = instance_double(Rainger::Client)
    tool_call = { "id" => "call_1", "function" => { "name" => "echo", "arguments" => { "text" => "hi" }.to_json } }
    allow(client).to receive(:chat).and_return(
      { "choices" => [{ "message" => message(role: "assistant", tool_calls: [tool_call]) }] },
      { "choices" => [{ "message" => message(role: "assistant", content: "done") }] }
    )

    assistant_messages = []
    tool_results = []

    described_class.run(
      messages: [{ role: "user", content: "hi" }], model: :local, tools: [EchoTool], client: client
    ) do |hooks|
      hooks.on_assistant_message { |msg| assistant_messages << msg }
      hooks.on_tool_result { |msg| tool_results << msg }
    end

    expect(assistant_messages.size).to eq(2)
    expect(tool_results.size).to eq(1)
  end
end
