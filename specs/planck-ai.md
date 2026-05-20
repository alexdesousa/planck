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
- Runtime model discovery for local providers (Ollama, llama.cpp, Custom OpenAI-compatible)
- JSON config loader for local model configuration
- Clean public API with full `@spec` coverage

## Core structs

### `Planck.AI.Model`

```elixir
%Planck.AI.Model{
  id: String.t(),                # user-facing alias (e.g. "sonnet")
  model: String.t() | nil,       # provider model identifier (e.g. "claude-sonnet-4-6");
                                  # falls back to id when nil
  name: String.t(),
  provider: atom(),              # :anthropic | :openai | :google
  context_window: pos_integer(),
  max_tokens: pos_integer(),
  supports_thinking: boolean(),
  input_types: [:text | :image | :image_url | :file | :video_url],
  base_url: String.t() | nil,   # nil = provider default; set for local/custom endpoints
  api_key: String.t() | nil,    # reserved; API keys are resolved from env at request time
  identifier: String.t() | nil, # uppercase tag (e.g. "NVIDIA") used to derive the API key
                                 # env var at request time (NVIDIA_API_KEY); openai only
  has_api_key: boolean(),        # false = no key needed (Ollama, llama.cpp); adapter passes
                                 # "not-needed" and skips env-var lookup
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

OpenAI-compatible local servers (Ollama, llama.cpp, vLLM, etc.) use the `:openai`
provider with a `base_url`. Pass `base_url:` to `list_models/2` to discover available
models at runtime via `GET {base_url}/models`.

| Module | Catalog source |
|---|---|
| `Planck.AI.Models.Anthropic` | LLMDB |
| `Planck.AI.Models.OpenAI` | LLMDB (no `base_url`) or runtime HTTP (`base_url` set) |
| `Planck.AI.Models.Google` | LLMDB |

## Config loader — `Planck.AI.Config`

`from_config/2` builds `[Model.t()]` from the v0.1.6 config format:

```elixir
providers = %{
  "anthropic" => %{"type" => "anthropic"},
  "nvidia"    => %{"type" => "openai",
                   "base_url" => "https://integrate.api.nvidia.com/v1",
                   "identifier" => "NVIDIA"},
  "local"     => %{"type" => "openai",
                   "base_url" => "http://localhost:11434",
                   "has_api_key" => false}
}

models = [
  %{"id" => "sonnet",   "model" => "claude-sonnet-4-6",           "provider" => "anthropic"},
  %{"id" => "llama70b", "model" => "meta/llama-3.3-70b-instruct", "provider" => "nvidia"}
]

Planck.AI.Config.from_config(providers, models)
# => [%Model{id: "sonnet", model: "claude-sonnet-4-6", provider: :anthropic}, ...]
```

Invalid entries are skipped with a warning logged at `:warning`.

## Context translation — `Planck.AI.Adapter`

The only module that knows req_llm's input shape.

```elixir
@spec to_req_llm(Model.t(), Context.t(), keyword()) ::
  {model_spec :: String.t() | map(), req_llm_context :: ReqLLM.Context.t(), opts :: keyword()}
```

For `:openai` with a `base_url`, passes `%{provider: :openai, id: model || id}` as a map
to bypass LLMDB catalog validation (local servers are not in the cloud catalog).
Without a `base_url`, passes `"openai:#{model || id}"` — a string spec that goes through
LLMDB. The `model` field is used as the API identifier when set; falls back to `id`.

API key resolution at request time:
- `has_api_key: false` → `"not-needed"` (no env lookup)
- `identifier` set → `<IDENTIFIER>_API_KEY`
- no identifier → `OPENAI_API_KEY` (fallback to `"not-needed"` if absent)

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
- `Config.from_config/2`: valid and invalid entries, unknown provider key, missing fields
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
