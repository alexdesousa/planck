# planck_ai

## Purpose

Typed, provider-agnostic LLM abstraction built on top of `req_llm`. Provides the
canonical types and streaming event protocol consumed by `planck_agent`. Published
to Hex as a standalone library.

## Dependencies

```elixir
{:req_llm, "~> 1.9"},
{:jason, "~> 1.4"},
{:nimble_options, "~> 1.0"}
```

## What planck_ai does (and doesn't do)

`req_llm` handles: HTTP transport, auth, request serialization, streaming, per-provider
parameter translation.

`planck_ai` adds:
- Typed structs the rest of the system speaks
- Stream normalization: req_llm chunks → `StreamEvent` tuples
- Model catalog with metadata (context window, cost, capabilities)
- Clean public API with full `@spec` coverage

## Core structs

### `Planck.AI.Model`

```elixir
%Planck.AI.Model{
  id: String.t(),
  name: String.t(),
  provider: atom(),              # :anthropic | :openai | :ollama | :llama_cpp
  context_window: pos_integer(),
  max_tokens: pos_integer(),
  supports_thinking: boolean(),
  input_types: [:text | :image],
  base_url: String.t() | nil,   # nil = provider default; set for llama.cpp, custom endpoints
  cost: %{input: float(), output: float(), cache_read: float(), cache_write: float()}
}
```

### `Planck.AI.Message`

```elixir
%Planck.AI.Message{
  role: :user | :assistant | :tool_result,
  content: [content_part()]
}

@type content_part ::
  {:text, String.t()}
  | {:image, binary(), String.t()}        # binary, mime_type
  | {:tool_call, String.t(), String.t(), map()}   # id, name, args
  | {:tool_result, String.t(), term()}    # id, result
  | {:thinking, String.t()}
```

### `Planck.AI.Context`

```elixir
%Planck.AI.Context{
  system: String.t() | nil,
  messages: [Planck.AI.Message.t()],
  tools: [Planck.AI.Tool.t()]
}
```

No inference params on Context — those are passed as keyword opts at the call site.

### `Planck.AI.Tool`

```elixir
%Planck.AI.Tool{
  name: String.t(),
  description: String.t(),
  parameters: map()    # JSON Schema map
}
```

### `Planck.AI.StreamEvent`

Type alias only, no struct:

```elixir
@type t ::
  {:text_delta, String.t()}
  | {:thinking_delta, String.t()}
  | {:tool_call_complete, %{id: String.t(), name: String.t(), args: map()}}
  | {:done, %{stop_reason: atom(), usage: map()}}
  | {:error, term()}
```

## Model catalog

Static modules per provider. No HTTP involved.

| Module | Content |
|---|---|
| `Planck.AI.Models.Anthropic` | claude-opus-4-5, claude-sonnet-4-6, claude-haiku-4-5 |
| `Planck.AI.Models.OpenAI` | gpt-4o, gpt-4o-mini |
| `Planck.AI.Models.Ollama` | static list (llama3.2, qwen2.5-coder, etc.) |
| `Planck.AI.Models.LlamaCpp` | factory function, not static list |

llama.cpp models vary by what the user has loaded locally, so the catalog entry is a
factory:

```elixir
Planck.AI.Models.LlamaCpp.model("llama3.2", base_url: "http://localhost:8080")
```

## Context translation — `Planck.AI.Adapter`

The only module that knows req_llm's input shape.

```elixir
@spec to_req_llm(Context.t(), keyword()) :: {model_spec :: term(), messages :: term(), opts :: keyword()}
@spec from_req_llm_message(term()) :: Message.t()
```

`to_req_llm/2` maps our `provider` atom + `base_url` to req_llm's model spec string.
For `:llama_cpp`, uses the OpenAI provider with `base_url` opt:

```elixir
defp req_llm_model_spec(%Model{provider: :llama_cpp, id: id, base_url: url}),
  do: {"openai:#{id}", base_url: url}
```

## Stream normalization — `Planck.AI.Stream`

Simple `Stream.map/2` — no stateful accumulation needed because `req_llm` already
decodes tool call arguments before emitting chunks.

```
%{type: :content,   text: t}                 → {:text_delta, t}
%{type: :thinking,  text: t}                 → {:thinking_delta, t}
%{type: :tool_call, name: n, arguments: a}   → {:tool_call_complete, %{name: n, args: a}}
%{type: :meta,      metadata: m}             → {:done, %{stop_reason: ..., usage: ...}}
```

## Public API

```elixir
# Returns a lazy Stream of StreamEvent tuples. Caller controls consumption.
@spec stream(Model.t(), Context.t(), keyword()) :: Enumerable.t()

# Blocks, collects the stream into a completed Message.
@spec complete(Model.t(), Context.t(), keyword()) :: {:ok, Message.t()} | {:error, term()}

# Model catalog queries.
@spec list_providers() :: [atom()]
@spec list_models(atom()) :: [Model.t()]
@spec get_model(atom(), String.t()) :: {:ok, Model.t()} | {:error, :not_found}
```

Keyword opts (e.g. `temperature: 0.7`, `max_tokens: 2048`) are forwarded directly to
`req_llm`. Provider-specific parameter filtering is handled by req_llm internally.
`complete/3` is implemented as `stream/3` reduced into a `Message` — no separate logic.

## Tool DSL — `Planck.AI.Tool.DSL`

Thin macro sugar. Builds a `%Planck.AI.Tool{}` struct with less boilerplate.
Implemented last — the struct is what matters.

## Testing strategy

### Unit tests (no HTTP)

- Struct construction and defaults
- Model catalog: `get_model`, `list_models`, unknown provider/id
- `Adapter.to_req_llm/2`: assert output shape for each content part type
- `Stream.from_req_llm/1`: feed mock `StreamChunk` list, assert event sequence
- Tool DSL: macro output matches hand-built struct

### Integration tests (mocked via Mox)

`Planck.AI.ReqLLMBehaviour` wraps `ReqLLM.stream_text/3`. The real module is used in
production; `MockReqLLM` is injected in tests via application config.

```elixir
# test/support/mocks.ex
Mox.defmock(Planck.AI.MockReqLLM, for: Planck.AI.ReqLLMBehaviour)
```

Test cases:
- `stream/3` happy path: mock emits chunks, assert correct `StreamEvent` sequence
- `complete/3` happy path: assert `{:ok, %Message{}}`
- Error path: mock returns `{:error, reason}`, assert propagation

## Build order

```
1. Core structs       — no deps, fully testable in isolation
2. Model catalog      — no deps, pure data
3. Stream normalize   — depends only on ReqLLM.StreamChunk shape
4. Adapter            — depends on structs + req_llm call signature
5. Public API         — wires stream + adapter together
6. Tool DSL           — syntactic sugar, last
```
