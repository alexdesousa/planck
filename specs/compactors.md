# Compactors

A compactor is an optional hook that `Planck.Agent` calls before each LLM turn
to manage context length. When context grows too long, the compactor summarises
older messages into a single checkpoint, keeping only recent messages verbatim.

## The `on_compact` hook protocol

Any function with arity 1 is a valid `on_compact` value. The
`Planck.Agent.Compactor` behaviour formalises this contract for module-based
compactors:

```elixir
@type on_compact ::
  ([Planck.Agent.Message.t()] ->
    {:compact,
      summary_msg :: Planck.Agent.Message.t(),
      kept :: [Planck.Agent.Message.t()]}
    | :skip)
```

- **Input**: the messages since the last summary checkpoint (the "active window").
- **`:skip`**: leave messages unchanged and proceed.
- **`{:compact, summary_msg, kept}`**: replace the active window with `summary_msg`
  followed by `kept`. `summary_msg` should have role `{:custom, :summary}` to be
  stored as a checkpoint in the session and recognized by future compaction passes.

The hook runs inside `handle_continue(:run_llm, state)` — it is synchronous and
must return promptly.

## Default compactor

`Planck.Agent.Compactor.build/2` returns a ready-to-use `on_compact` function:

```elixir
on_compact = Planck.Agent.Compactor.build(model,
  ratio:       0.8,   # compact when history reaches 80% of context_window
  keep_recent: 10     # keep last 10 messages verbatim, outside the summary
)
```

Token count is estimated as `chars ÷ 4`. When the threshold is exceeded, the
compactor calls the LLM with a structured prompt to produce the summary. On LLM
failure it returns `:skip` — original messages are left unchanged.

The summary prompt instructs the LLM to:
- Describe completed work and resolved decisions briefly
- State clearly what is currently being worked on and the most recent requests
- Preserve key facts, file paths, decisions, and constraints still relevant

## Custom compactors via `.exs` files

Place a `.exs` file anywhere on the filesystem. The file must define a module
that implements the `Planck.Agent.Compactor` behaviour. Using a module (rather
than a bare function) lets you define private helper functions alongside the
main callback:

```elixir
# .planck/compactors/my_compactor.exs
defmodule MyApp.Compactor do
  @behaviour Planck.Agent.Compactor

  @impl true
  def compact(messages) do
    case summarise(messages) do
      {:ok, text} ->
        summary_msg = Planck.Agent.Message.new({:custom, :summary}, [{:text, text}])
        kept = Enum.take(messages, -5)
        {:compact, summary_msg, kept}

      :error ->
        :skip
    end
  end

  defp summarise(messages) do
    # your summarisation logic
    text = Enum.map_join(messages, "\n", &extract_text/1)
    {:ok, text}
  end

  defp extract_text(%{content: content}) do
    Enum.map_join(content, "", fn
      {:text, t} -> t
      _ -> ""
    end)
  end
end
```

Load it with `Planck.Agent.Compactor.load/1`:

```elixir
{:ok, on_compact} = Planck.Agent.Compactor.load(".planck/compactors/my_compactor.exs")
```

Or configure it globally via environment variable so the runtime loads it at
startup:

```
PLANCK_AGENT_COMPACTOR=/path/to/my_compactor.exs
```

When `PLANCK_AGENT_COMPACTOR` is set, it replaces the default `Compactor`
entirely — there is no merging.

## Custom compactors passed directly

Pass any function directly at agent start time to override on a per-agent basis:

```elixir
Planck.Agent.start_link(
  id: "agent-1",
  model: model,
  on_compact: fn messages -> ... end
)
```

## API

```elixir
# Behaviour callback — implement this in your custom compactor module.
@callback compact(messages :: [Message.t()]) ::
            {:compact, summary :: Message.t(), kept :: [Message.t()]} | :skip

# Build the default token-count-based compactor.
@spec build(Planck.AI.Model.t(), opts()) ::
        ([Message.t()] -> :skip | {:compact, Message.t(), [Message.t()]})

# Load a custom compactor from a .exs file defining a module with compact/1.
@spec load(Path.t()) :: {:ok, on_compact()} | {:error, String.t()}
```

## Configuration

| Env var                  | Config key    | Default | Description                             |
|--------------------------|---------------|---------|-----------------------------------------|
| `PLANCK_AGENT_COMPACTOR` | `:compactor`  | `nil`   | Path to a custom `.exs` compactor file  |

```elixir
config :planck_agent, :compactor, "/path/to/my_compactor.exs"
```

When `nil`, agents without an explicit `on_compact:` option do not compact at
all. Use `Planck.Agent.Compactor.build/2` to attach the default strategy.
