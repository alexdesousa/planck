# Planck.AI

`planck_ai` is a typed LLM provider abstraction for Elixir, built on top of
[`req_llm`](https://hex.pm/packages/req_llm). It gives you a single, consistent
interface for streaming and completing requests across Anthropic, OpenAI, Google
Gemini, Ollama, and llama.cpp — without leaking provider-specific details into
your application.

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
| Ollama (local) | `:ollama` | — |
| llama.cpp (local) | `:llama_cpp` | — |

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
Local providers (`:ollama`, `:llama_cpp`) query the running server at call time.

```elixir
# List all providers
AI.list_providers()
#=> [:anthropic, :openai, :google, :ollama, :llama_cpp]

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

### Ollama

Ollama has no static catalog — the available models depend on what you have
pulled into your local instance. Use `all/1` to discover them at runtime, or
`model/2` to build one directly:

```elixir
# Discover all models from the running server
models = Planck.AI.Models.Ollama.all()
models = Planck.AI.Models.Ollama.all(base_url: "http://10.0.0.5:11434")

# Build a model struct directly (no server call)
model = Planck.AI.Models.Ollama.model("llama3.2")
model = Planck.AI.Models.Ollama.model("deepseek-r1",
  base_url:          "http://10.0.0.5:11434",
  context_window:    64_000,
  max_tokens:        8_192,
  supports_thinking: true
)
```

Ollama must be running at `http://localhost:11434` (or the specified `base_url`).
No API key needed.

### llama.cpp

llama.cpp has no static catalog because the loaded model depends on your server.
Use `all/1` to discover models, or `model/2` to build one directly:

```elixir
# Discover models from the running server
models = Planck.AI.Models.LlamaCpp.all(base_url: "http://localhost:8080")
models = Planck.AI.Models.LlamaCpp.all(base_url: "http://10.0.0.5:8080", api_key: "secret")

# Build a model struct directly
model = Planck.AI.Models.LlamaCpp.model("mistral-7b",
  base_url:       "http://localhost:8080",
  context_window: 32_768,
  max_tokens:     4_096
)
```

Pass `api_key:` when the server requires a token — it is sent as a Bearer
header in both `all/1` (discovery) and via `req_llm` during inference.

## Per-model inference defaults

`%Planck.AI.Model{}` has a `default_opts` field for inference parameters that
should apply to every call for that model. Opts passed explicitly to `stream/3`
or `complete/3` override the defaults.

```elixir
model = Planck.AI.Models.LlamaCpp.model("qwen3-coder",
  default_opts: [temperature: 1.0, top_p: 0.95, top_k: 64, min_p: 0.01]
)

# temperature: 1.0 applies unless overridden
AI.stream(model, context)

# temperature: 0.3 overrides the model default
AI.stream(model, context, temperature: 0.3)
```

## Config file loader

`Planck.AI.Config` loads a list of models from a JSON file — useful for
configuring local servers without hardcoding model structs in your application.

### JSON format

Only `"id"` and `"provider"` are required. All other fields are optional and
have the same defaults as `model/2`.

```json
[
  {
    "id": "qwen3-coder-q4",
    "provider": "llama_cpp",
    "name": "Qwen3 Coder Q4",
    "base_url": "http://localhost:8080",
    "context_window": 40960,
    "max_tokens": 8192,
    "default_opts": {
      "temperature": 1.0,
      "top_p": 0.95,
      "top_k": 40,
      "min_p": 0.01
    }
  },
  {
    "id": "llama3.2:latest",
    "provider": "ollama",
    "context_window": 4096
  }
]
```

Valid `"provider"` values: `"anthropic"`, `"openai"`, `"google"`, `"ollama"`,
`"llama_cpp"`.

Valid `"input_types"` values: `"text"`, `"image"`, `"image_url"`, `"file"`,
`"video_url"`. Note that `"video_url"` is only supported by Google Gemini.

### Loading

```elixir
{:ok, models} = Planck.AI.Config.load("config/models.json")

model = Enum.find(models, &(&1.id == "qwen3-coder-q4"))
AI.stream(model, context)
```

Invalid entries are skipped with a warning; the file read or JSON parse
returning an error is propagated as `{:error, reason}`.

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
