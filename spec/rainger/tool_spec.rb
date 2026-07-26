require "spec_helper"

class VaultSearchTool < Rainger::Tool
  tool_name "vault_search"
  description "Search the vault"

  param :query, :string, "The search query", required: true
  param :date_from, :string, "Earliest date"

  def call(query:, date_from: nil)
    emit(:source, capture_id: 1)
    "results for #{query} from #{date_from.inspect}"
  end
end

class ScopedTool < Rainger::Tool
  tool_name "scoped"
  description "Uses context"
  context :default_week_of

  def call
    "week: #{default_week_of}"
  end
end

class HaltingTool < Rainger::Tool
  tool_name "halting"
  description "Halts the loop"

  def call
    halt!("done early")
  end
end

class ExplodingTool < Rainger::Tool
  tool_name "exploding"
  description "Always raises"

  def call
    raise "kaboom"
  end
end

class ConflictingTool < Rainger::Tool
  tool_name "conflicting"
  description "Declares both param and a custom schema"

  param :query, :string, "The search query", required: true
  schema { { type: "object", properties: {} } }

  def call(query:)
    query
  end
end

RSpec.describe Rainger::Tool do
  describe ".definition" do
    it "builds a frozen OpenAI function definition from param declarations" do
      definition = VaultSearchTool.definition

      expect(definition).to be_frozen
      expect(definition[:type]).to eq("function")
      expect(definition[:function][:name]).to eq("vault_search")
      expect(definition[:function][:parameters][:required]).to eq(["query"])
      expect(definition[:function][:parameters][:properties][:query][:type]).to eq("string")
    end

    it "raises when a tool declares both param and a custom schema block" do
      expect { ConflictingTool.definition }.to raise_error(ArgumentError, /both `param` and a custom `schema`/)
    end
  end

  describe ".dispatch" do
    it "parses JSON args, drops unknown keys, and returns content + events" do
      result = VaultSearchTool.dispatch({ "query" => "cats", "bogus" => "x" }.to_json)

      expect(result[:content]).to eq("results for cats from nil")
      expect(result[:events]).to eq([{ kind: :source, payload: { capture_id: 1 } }])
    end

    it "injects context into declared readers" do
      result = ScopedTool.dispatch({}, context: { default_week_of: "2026-07-20" })

      expect(result[:content]).to eq("week: 2026-07-20")
    end

    it "rescues errors into an {error:} content payload" do
      result = ExplodingTool.dispatch({})

      expect(JSON.parse(result[:content])).to eq({ "error" => "kaboom" })
      expect(result[:events]).to eq([])
    end

    it "lets LoopHalted propagate for the Loop to catch" do
      expect { HaltingTool.dispatch({}) }.to raise_error(Rainger::LoopHalted) do |error|
        expect(error.content).to eq("done early")
      end
    end
  end
end
