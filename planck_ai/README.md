# Planck.AI

`planck_ai` is a typed LLM provider abstraction for Elixir, built on top of
[`req_llm`](https://hex.pm/packages/req_llm). It gives you a single, consistent
interface for streaming and completing requests across Anthropic, OpenAI, Google
Gemini, and any OpenAI-compatible endpoint — without leaking provider-specific
details into your application.

## Installation

```elixir
# mix.exs
{:planck_ai, "~> 0.1"}
```

## Providers

| Provider | Atom | API key env var |
|---|---|---|
| Anthropic (Claude) | `:anthropic` | `ANTHROPIC_API_KEY` |
| OpenAI (GPT) | `:openai` | `OPENAI_API_KEY` |
| Google (Gemini) | `:google` | `GOOGLE_API_KEY` |
| OpenAI-compatible (NVIDIA, Groq, Ollama, llama.cpp, …) | `:openai` + `base_url` | `<IDENTIFIER>_API_KEY` or none |

OpenAI-compatible endpoints (NVIDIA NIM, Groq, Ollama, llama.cpp, vLLM, etc.)
use the `:openai` provider atom with a `base_url` set. The optional `identifier`
field (e.g. `"NVIDIA"`) derives the API key env var (`NVIDIA_API_KEY`); if
omitted it falls back to `OPENAI_API_KEY`, or `"not-needed"` when no key exists.

## Quick start

```elixir
alias Planck.AI
alias Planck.AI.{Context, Message}

# 1. Pick a model from the catalog
{:ok, model} = AI.get_model(:anthropic, "claude-sonnet-4-6")

# 2. Build a context
context = %Context{
  system: "You are a helpful assistant.",
  messages: [
    %Message{role: :user, content: [{:text, "What is the Planck length?"}]}
  ]
}

# 3. Stream the response
model
|> AI.stream(context, temperature: 0.7)
|> Enum.each(fn
  {:text_delta, text} -> IO.write(text)
  {:done, _meta}      -> IO.puts("")
  {:error, reason}    -> IO.puts("Error: #{inspect(reason)}")
  _                   -> :ok
end)

# Or block for the full message
{:ok, %Message{content: content}} = AI.complete(model, context)
```

## Model catalog

Cloud providers (`:anthropic`, `:openai`, `:google`) source their catalog from
a bundled LLMDB snapshot loaded offline at startup — no network call required.

```elixir
# List all providers
AI.list_providers()
#=> [:anthropic, :openai, :google]

# List models for a provider
AI.list_models(:anthropic)
#=> [%Planck.AI.Model{id: "claude-opus-4-7", ...}, ...]

# Fetch a specific model by ID
{:ok, model} = AI.get_model(:anthropic, "claude-sonnet-4-6")
{:error, :not_found} = AI.get_model(:anthropic, "does-not-exist")
```

### Anthropic

```elixir
models = AI.list_models(:anthropic)
{:ok, model} = AI.get_model(:anthropic, "claude-sonnet-4-6")
```

Requires `ANTHROPIC_API_KEY`.

### OpenAI

```elixir
models = AI.list_models(:openai)
{:ok, model} = AI.get_model(:openai, "gpt-4o")
```

Requires `OPENAI_API_KEY`.

### Google Gemini

```elixir
models = AI.list_models(:google)
{:ok, model} = AI.get_model(:google, "gemini-2.5-flash")
```

Requires `GOOGLE_API_KEY`. Models that support extended thinking have
`supports_thinking: true` set in the catalog. To enable thinking on a request,
pass the budget via the Google-specific opt:

```elixir
AI.stream(model, context, google_thinking_budget: 8_192)
```

### OpenAI-compatible endpoints

Any OpenAI-compatible server (NVIDIA NIM, Groq, Ollama, llama.cpp, vLLM, etc.)
uses the `:openai` provider with a `base_url`. Pass `base_url:` to `list_models/2`
to discover available models at runtime:

```elixir
# Discover models from NVIDIA NIM
models = AI.list_models(:openai, base_url: "https://integrate.api.nvidia.com/v1", identifier: "NVIDIA")

# Discover models from a local Ollama instance
models = AI.list_models(:openai, base_url: "http://localhost:11434")

# Discover models from a local llama.cpp server
models = AI.list_models(:openai, base_url: "http://localhost:8080")
```

API keys are resolved from the environment at request time. The `identifier`
field determines the env var name: `"NVIDIA"` → `NVIDIA_API_KEY`. When
`identifier` is nil, `OPENAI_API_KEY` is used. For keyless local servers (Ollama,
llama.cpp), neither env var needs to be set — the adapter falls back to
`"not-needed"`.

## Per-model inference defaults

`%Planck.AI.Model{}` has a `default_opts` field for inference parameters that
should apply to every call for that model. Opts passed explicitly to `stream/3`
or `complete/3` override the defaults.

```elixir
model = %Planck.AI.Model{
  id: "meta/llama-3.3-70b-instruct",
  provider: :openai,
  base_url: "https://integrate.api.nvidia.com/v1",
  identifier: "NVIDIA",
  context_window: 128_000,
  max_tokens: 4_096,
  default_opts: [temperature: 0.6, receive_timeout: 600_000]
}

# temperature: 0.6 applies unless overridden
AI.stream(model, context)

# temperature: 0.3 overrides the model default
AI.stream(model, context, temperature: 0.3)
```

## Config loader — `Planck.AI.Config`

`Planck.AI.Config.from_config/2` builds a list of `%Model{}` structs from the
v0.1.6 config format: a `providers` map (user-keyed) and a `models` list where
each entry references a provider by key.

```elixir
providers = %{
  "anthropic" => %{"type" => "anthropic"},
  "nvidia"    => %{"type" => "openai",
                   "base_url"   => "https://integrate.api.nvidia.com/v1",
                   "identifier" => "NVIDIA"},
  "local"     => %{"type" => "openai",
                   "base_url"    => "http://localhost:11434",
                   "has_api_key" => false}
}

models = [
  %{"id" => "sonnet",   "model" => "claude-sonnet-4-6",           "provider" => "anthropic"},
  %{"id" => "llama70b", "model" => "meta/llama-3.3-70b-instruct", "provider" => "nvidia",
    "params" => %{"temperature" => 0.6, "receive_timeout" => 600_000}},
  %{"id" => "llama3.2", "model" => "llama3.2",                    "provider" => "local"}
]

models = Planck.AI.Config.from_config(providers, models)
# => [%Planck.AI.Model{id: "sonnet", model: "claude-sonnet-4-6", provider: :anthropic}, ...]

model = Enum.find(models, &(&1.id == "llama70b"))
AI.stream(model, context)
```

Invalid entries (unknown provider key, unknown provider type, missing required
fields) are skipped with a warning; valid entries are returned.

### Provider entry fields

| Field | Required | Description |
|---|---|---|
| `"type"` | yes | `"anthropic"`, `"openai"`, or `"google"` |
| `"base_url"` | no | Custom endpoint — required for OpenAI-compatible local servers |
| `"identifier"` | no | Uppercase tag for API key env var (`"NVIDIA"` → `NVIDIA_API_KEY`) |
| `"has_api_key"` | no | `false` skips key lookup entirely (Ollama, llama.cpp). Default: `true` |

### Model entry fields

| Field | Required | Description |
|---|---|---|
| `"id"` | yes | User alias — used to look up the model |
| `"model"` | yes | Provider model identifier sent to the API |
| `"provider"` | yes | Key referencing a `providers` entry |
| `"params"` | no | Inference parameters (`temperature`, `max_tokens`, etc.) |

## Streaming events

`AI.stream/3` returns a lazy `Enumerable` of tagged tuples:

| Event | Meaning |
|---|---|
| `{:text_delta, string}` | A chunk of assistant text |
| `{:thinking_delta, string}` | A chunk of extended-thinking text |
| `{:tool_call_complete, %{id:, name:, args:}}` | A fully-assembled tool call |
| `{:done, %{stop_reason:, usage:}}` | Stream finished; usage stats included |
| `{:error, reason}` | Transport or API error; stream halts |

Exceptions raised during enumeration (e.g. a dropped HTTP connection) are
caught and emitted as `{:error, exception}` events, so the stream never raises.

## Streaming patterns

### Print text as it arrives

```elixir
AI.stream(model, context)
|> Enum.each(fn
  {:text_delta, text} -> IO.write(text)
  {:done, _}          -> IO.puts("")
  {:error, reason}    -> IO.puts("\nError: #{inspect(reason)}")
  _                   -> :ok
end)
```

### Forward events to another process

Since `AI.stream/3` returns a lazy enumerable, you can run it in a `Task` and
`send` each event to a LiveView or any other process as chunks arrive:

```elixir
parent = self()

Task.start(fn ->
  AI.stream(model, context)
  |> Stream.each(fn event -> send(parent, {:llm_event, event}) end)
  |> Stream.run()
end)

# Handle in a LiveView or GenServer:
def handle_info({:llm_event, {:text_delta, text}}, socket) do
  {:noreply, update(socket, :response, &(&1 <> text))}
end

def handle_info({:llm_event, {:done, _}}, socket) do
  {:noreply, assign(socket, :streaming, false)}
end

def handle_info({:llm_event, _}, socket), do: {:noreply, socket}
```

## Inference parameters

All keyword opts accepted by `AI.stream/3` and `AI.complete/3` are forwarded
directly to `req_llm`, which handles per-provider translation:

```elixir
AI.complete(model, context,
  temperature: 0.8,
  top_p:       0.95,
  max_tokens:  2_048
)
```

## Tool calling

Define tools with `Tool.new/1` and attach them to the context:

```elixir
alias Planck.AI.Tool

read_file = Tool.new(
  name: "read_file",
  description: "Read the contents of a file",
  parameters: %{
    "type" => "object",
    "properties" => %{
      "path" => %{"type" => "string", "description" => "Absolute path to the file"}
    },
    "required" => ["path"]
  }
)

context = %Context{
  system: "You are a coding assistant.",
  messages: [
    %Message{role: :user, content: [{:text, "Show me lib/app.ex"}]}
  ],
  tools: [read_file]
}

{:ok, %Message{content: content}} = AI.complete(model, context)

# Inspect the tool calls in the response
for {:tool_call, id, name, args} <- content do
  IO.inspect({id, name, args})
end
```

To complete the loop, append a tool result message and call `complete/3` again:

```elixir
result_msg = %Message{
  role: :tool_result,
  content: [{:tool_result, call_id, File.read!(args["path"])}]
}

updated_context = %{context | messages: context.messages ++ [assistant_msg, result_msg]}
{:ok, final} = AI.complete(model, updated_context)
```

## Multimodal input

Four content part types carry non-text data:

```elixir
# Binary image
{:image, File.read!("photo.png"), "image/png"}

# Image by URL (all cloud providers)
{:image_url, "https://example.com/photo.png"}

# Binary file / document (Anthropic PDFs, Google files)
{:file, File.read!("report.pdf"), "application/pdf"}

# Video by URL (Google Gemini only)
{:video_url, "https://example.com/clip.mp4"}
```

```elixir
%Message{
  role: :user,
  content: [
    {:image_url, "https://example.com/screenshot.png"},
    {:text, "What do you see in this image?"}
  ]
}
```

Support depends on the model's `input_types` field in the catalog.
