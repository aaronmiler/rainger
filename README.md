# rAInger

Shared LLM plumbing for Rails apps talking to any OpenAI-compatible chat/completions
endpoint. One client, one tool DSL, one agent loop — each app keeps its own prompts,
tools, and policies, but stops re-implementing the mechanics.

## Design principles

- **OpenAI wire format, no provider abstraction.** The client speaks plain OpenAI
  HTTP — no per-provider adapters. It's built and tested against a LiteLLM proxy,
  but anything speaking the same wire format works; `BudgetExceeded` specifically
  matches LiteLLM's error shape.
- **The gem owns mechanics, apps own policy.** Tool definitions, prompts, routing
  maps, and persistence live in the app; JSON-schema generation, dispatch, the loop,
  and error handling live in the gem.
- **Zero runtime dependencies beyond `activesupport`.** Net::HTTP for transport.
- **Budgets/rate limits belong in the proxy**, not Ruby. The gem contributes typed
  errors and per-call usage instrumentation.

## Installation

```ruby
# Gemfile
gem "rainger", github: "..."
```

## Configuration

```ruby
Rainger.configure do |c|
  c.base_url = ENV.fetch("LITELLM_BASE_URL")
  c.api_key  = ENV.fetch("LITELLM_API_KEY", "none")
  c.app_name = "delta"                       # User-Agent + instrumentation tag

  # Used whenever a call site omits model:. String or 0-arity lambda.
  c.default_model = -> { Setting.get("local_model") }

  # A symbol passed as model: resolves through this map (string or 0-arity
  # lambda); a string passes through to LiteLLM verbatim.
  c.models = {
    local: -> { Setting.get("local_model") },
    cloud: -> { Setting.get("cloud_model") }
  }

  c.app_dir = "rainger"        # app/rainger — see "App-side conventions" below
  # c.prompt_path = Rails.root.join("app/prompts")  # override Prompt's default dir
end
```

## Client

```ruby
Rainger.chat(messages, model: nil, tools: nil, temperature: nil, max_tokens: nil)
# model: omit to use c.default_model; otherwise a models: alias or a literal string
# => parsed response hash (full body — dig "choices", 0, "message" as usual)

Rainger.embed(texts, model: "embed-model")
# => Array<Array<Float>>

Rainger.extract_json(text)
# => Hash/Array or nil — tolerant pull: strips <think>/<thinking> blocks, prefers a
#    fenced ```json block, falls back to the outermost {...} / [...]
```

Errors: `Rainger::APIError` (status + truncated body), `Rainger::ConnectionError`,
with `RateLimited` (429) and `BudgetExceeded` (LiteLLM budget error shape)
subclasses. Every call emits `rainger.chat` / `rainger.embed` `AS::Notifications`
events carrying model, duration, and the response's `usage` token counts.

## Tool DSL

```ruby
class VaultSearchTool < Rainger::Tool
  tool_name   "vault_search"        # optional; defaults to demodulized snake_case minus "_tool"
  description "Search the user's vault for past captures, meetings, and syntheses."

  param :query,     :string, "The search query", required: true
  param :date_from, :string, "Earliest date to include (ISO 8601). Omit for no lower bound."
  param :date_to,   :string, "Latest date to include (ISO 8601). Omit for no upper bound."

  def call(query:, date_from: nil, date_to: nil)
    results = Rag.new.search(query, k: 8, where: date_filter(date_from, date_to))
    results.each { |r| emit(:source, capture_id: r[:capture_id], vault_path: r[:vault_path]) }
    format(results).presence || "No results found for: #{query}"
  end
end
```

- `param name, type, description, required:, enum:, items:` generates the JSON
  schema. Anything the declarative form can't express drops to a raw `schema { ... }`
  block.
- `.definition` is the frozen `{type: "function", function: {...}}` hash passed to
  LiteLLM — always derived, never hand-written.
- `#call(**args)` receives keyword args parsed from the model's JSON; unknown keys
  are dropped so a hallucinated argument can't crash dispatch.
- `emit(kind, payload)` is the out-of-band channel for sources/side effects,
  collected and grouped on the `Loop::Result`.
- Errors raised in `call` are rescued and fed back to the model as `{error: message}`;
  `ActiveRecord::RecordNotFound`/`RecordInvalid` map to clean messages. `halt!(content)`
  aborts the loop early with a final answer.
- `context :name` declares a reader backed by the `context:` hash passed at loop
  start (e.g. `default_week_of`).

The tool set passed to the loop *is* the allowlist — an unknown tool name from the
model returns an error result, never a `send`.

## Loop runner

```ruby
result = Rainger::Loop.run(
  messages: messages,                       # [{role:, content:}, ...] incl. system
  model: :local,
  tools:    [VaultSearchTool, ManageTaskTool, RememberTool],
  context:  { default_week_of: week_of },   # handed to every tool instance
  max_iterations: 6,                        # default 5; gem clamps to HARD_CAP (10)
  nudge: { at: 3, content: "Synthesize what you have; only search again if critical info is missing." },
  strip_thinking: true                      # remove <think>/<thinking> blocks from the answer
) do |hooks|
  hooks.on_assistant_message { |msg| save_message(msg) }   # incl. tool_calls
  hooks.on_tool_result       { |msg| save_message(msg) }
end

result.content      # final answer string
result.events       # { source: [...], side_effect: [...] } from emit()
result.messages     # full transcript
result.iterations
result.capped?      # hit max_iterations
```

`max_iterations` is clamped to a gem-enforced hard ceiling
(`Rainger::Loop::HARD_CAP = 10`) that no caller can exceed. At the cap, the default
behavior is one more call without tools, forcing a final answer; `on_cap: :bail`
returns `nil` content instead.

## Prompt

```ruby
Rainger::Prompt.render("query_runner", date: ..., persona: ...)
# renders app/rainger/prompts/query_runner.md.erb (or c.prompt_path)
```

## App-side conventions

Everything Rainger-related lives under `app/rainger/` — tool classes flat at the
root, prompts in a subdirectory:

```
app/
  rainger/
    vault_search_tool.rb      # VaultSearchTool
    manage_task_tool.rb       # ManageTaskTool
    prompts/
      query_runner.md.erb     # Rainger::Prompt.render("query_runner")
  services/
    query_runner.rb           # loop orchestrators stay ordinary services
```

This needs zero autoload config: Rails already treats `app/rainger` as an autoload
root, so tool classes come out as top-level constants, and `prompts/` contains no
Ruby so zeitwerk ignores it. The root name is configurable (`c.app_dir`). Loop
orchestrators are deliberately not given a home here — they're plain service
objects.

## Development

```
bundle install
bundle exec rspec   # or: bundle exec rake
```
