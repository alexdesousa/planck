# planck_ai

## Purpose

Typed, provider-agnostic LLM abstraction built on top of `req_llm`. Provides the
canonical types and streaming event protocol consumed by `planck_agent`. Published
to Hex as a standalone library.

## Dependencies

```elixir
{:req_llm, "~> 1.9"},
{:req, "~> 0.5"},
{:jason, "~> 1.4"},
{:nimble_options, "~> 1.0"}
```

## What planck_ai does (and doesn't do)

`req_llm` handles: HTTP transport, auth, request serialization, streaming, per-provider
parameter translation.

`planck_ai` adds:
- Typed structs the rest of the system speaks
- Lazy event-tuple stream: req_llm chunks → `Stream.t()` tuples with stateful tool call assembly
- Model catalog with metadata (context window, capabilities) sourced from LLMDB for cloud providers
- Runtime model discovery for local providers (Ollama, llama.cpp)
- JSON config loader for local model configuration
- Clean public API with full `@spec` coverage

## Core structs

### `Planck.AI.Model`

```elixir
%Planck.AI.Model{
  id: String.t(),
  name: String.t(),
  provider: atom(),              # :anthropic | :openai | :google | :ollama | :llama_cpp
  context_window: pos_integer(),
  max_tokens: pos_integer(),
  supports_thinking: boolean(),
  input_types: [:text | :image | :image_url | :file | :video_url],
  base_url: String.t() | nil,   # nil = provider default; set for llama.cpp, Ollama, custom endpoints
  api_key: String.t() | nil,    # nil = read from env; set for local servers that require a token
  default_opts: keyword()        # inference params applied on every call unless overridden
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
  | {:image, binary(), String.t()}              # binary, mime_type
  | {:image_url, String.t()}
  | {:file, binary(), String.t()}               # binary, mime_type
  | {:video_url, String.t()}
  | {:thinking, String.t()}
  | {:tool_call, String.t(), String.t(), map()} # id, name, args
  | {:tool_result, String.t(), term()}          # id, result
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

Built with `Tool.new/1`:

```elixir
Tool.new(
  name: "ls",
  description: "List files in a directory",
  parameters: %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}, "required" => ["path"]}
)
```

### `Planck.AI.Stream`

Type alias (no struct) plus the `from_req_llm/1` normalization function:

```elixir
@type t ::
  {:text_delta, String.t()}
  | {:thinking_delta, String.t()}
  | {:tool_call_complete, %{id: String.t(), name: String.t(), args: map()}}
  | {:done, %{stop_reason: atom(), usage: map()}}
  | {:error, term()}
```

## Model catalog

Cloud providers (`:anthropic`, `:openai`, `:google`) source their catalog from LLMDB,
a bundled snapshot loaded into `:persistent_term` at startup — no network call required.

Local providers (`:ollama`, `:llama_cpp`) query the running server at call time via HTTP.

| Module | Catalog source |
|---|---|
| `Planck.AI.Models.Anthropic` | LLMDB |
| `Planck.AI.Models.OpenAI` | LLMDB |
| `Planck.AI.Models.Google` | LLMDB |
| `Planck.AI.Models.Ollama` | Runtime HTTP (`/api/tags`) |
| `Planck.AI.Models.LlamaCpp` | Runtime HTTP (`/models`) or `model/2` factory |

llama.cpp example:

```elixir
Planck.AI.Models.LlamaCpp.model("llama3.2", base_url: "http://localhost:8080")
```

## Config file loader — `Planck.AI.Config`

Loads a list of `%Model{}` structs from a JSON file. Useful for CLI tools and
applications that configure local servers without hardcoding model structs.

Two entry points:
- `load/1` — reads and parses a JSON file by path
- `from_list/1` — accepts a pre-decoded list of maps (for callers that parse a larger config)

## Context translation — `Planck.AI.Adapter`

The only module that knows req_llm's input shape.

```elixir
@spec to_req_llm(Model.t(), Context.t(), keyword()) ::
  {model_spec :: String.t() | map(), req_llm_context :: ReqLLM.Context.t(), opts :: keyword()}
```

For `:llama_cpp`, passes `%{provider: :openai, id: id}` as a map to bypass LLMDB catalog
validation (llama.cpp speaks the OpenAI API but is not in the cloud catalog).

## Stream normalization — `Planck.AI.Stream`

Stateful `Stream.resource`-based pipeline. Tool call arguments from req_llm arrive as
JSON fragments spread across multiple `:meta` chunks — the stream buffers them by index
and emits a single assembled `{:tool_call_complete, ...}` per tool call when the final
`:meta` chunk arrives.

```
:tool_call chunk (name, id)              → buffered (no event yet)
:meta chunk (tool_call_args fragment)    → buffered (no event yet)
:meta chunk (finish_reason, usage)       → {:tool_call_complete, ...}, {:done, ...}
:content chunk                           → {:text_delta, text}
:thinking chunk                          → {:thinking_delta, text}
unknown chunk                            → {:error, {:unknown_chunk, chunk}}
```

Exceptions raised during stream enumeration (e.g. dropped HTTP connection) are caught
and emitted as `{:error, exception}` events — the stream never raises.

## Public API

```elixir
# Returns a lazy Stream of Stream.t() tuples. Caller controls consumption.
@spec stream(Model.t(), Context.t()) :: Enumerable.t(Stream.t())
@spec stream(Model.t(), Context.t(), keyword()) :: Enumerable.t(Stream.t())

# Blocks, collects the stream into a completed Message.
@spec complete(Model.t(), Context.t()) :: {:ok, Message.t()} | {:error, term()}
@spec complete(Model.t(), Context.t(), keyword()) :: {:ok, Message.t()} | {:error, term()}

# Model catalog queries.
@spec list_providers() :: [atom()]
@spec list_models(atom()) :: [Model.t()]
@spec list_models(atom(), keyword()) :: [Model.t()]
@spec get_model(atom(), String.t()) :: {:ok, Model.t()} | {:error, :not_found}
@spec get_model(atom(), String.t(), keyword()) :: {:ok, Model.t()} | {:error, :not_found}
```

`opts` are forwarded directly to `req_llm` for inference parameters (`temperature:`,
`max_tokens:`, etc.) and merged with `model.default_opts` (caller opts win on conflict).
`complete/3` is implemented as `stream/3` reduced into a `Message` — no separate logic.

## Testing strategy

### Unit tests (no HTTP)

- Struct construction and defaults
- Model catalog: `get_model`, `list_models`, unknown provider/id
- `Adapter.to_req_llm/3`: assert output shape for each provider, content part type, message role
- `Stream.from_req_llm/1`: feed mock chunk list, assert event sequence including tool call assembly
- `Config.from_map/1`, `from_list/1`, `load/1`: valid and invalid entries
- `Tool.new/1`: struct construction

### Integration tests (mocked via Mox)

`Planck.AI.ReqLLMBehaviour` wraps `ReqLLM.stream_text/3`. The real module is used in
production; `MockReqLLM` is injected in tests via application config.

Mocks defined in `test/test_helper.exs`:

```elixir
Mox.defmock(Planck.AI.MockReqLLM, for: Planck.AI.ReqLLMBehaviour)
Mox.defmock(Planck.AI.MockHTTPClient, for: Planck.AI.HTTPClient)
```

Test cases:
- `stream/3` happy path: mock emits chunks, assert correct `Stream.t()` sequence
- `complete/3` happy path: assert `{:ok, %Message{}}`
- Tool call round-trip: identity + fragment + final meta → `{:tool_call_complete, ...}`
- Error path: mock returns `{:error, reason}`, assert propagation
