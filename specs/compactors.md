# Compactors

A compactor is an optional hook that `Planck.Agent` calls before each LLM turn
to manage context length. When context grows too long, the compactor summarises
older messages into a single checkpoint, keeping only recent messages verbatim.

## The `Planck.Agent.Hooks.Compactor` behaviour

```elixir
@callback compact(model :: Planck.AI.Model.t(), messages :: [Message.t()]) ::
            {:compact,
              summary_msg :: Planck.Agent.Message.t(),
              kept :: [Planck.Agent.Message.t()]}
            | :skip

@callback compact_timeout() :: pos_integer()
```

- **Input**: the model (for cost-aware strategies) and the messages since the
  last summary checkpoint (the "active window").
- **`:skip`**: leave messages unchanged and proceed.
- **`{:compact, summary_msg, kept}`**: replace the active window with `summary_msg`
  followed by `kept`. `summary_msg` should have role `{:custom, :summary}` to be
  stored as a checkpoint in the session and recognized by future compaction passes.

`use Planck.Agent.Hooks.Compactor` injects a default 30 000 ms `compact_timeout/0`.

## Dispatch

`Hooks.Compactor.compact/4` is the single dispatch entry point:

```elixir
Planck.Agent.Hooks.Compactor.compact(module, model, messages, sidecar_node)
```

- `module: nil` → runs the built-in LLM-based compactor locally.
- `module: MyMod` + `sidecar_node: nil` → calls `MyMod.compact/2` locally.
- `module: MyMod` + `sidecar_node: node` → `:rpc.call` to the sidecar node;
  falls back to the built-in compactor if the RPC fails.

## Built-in compactor

When `module` is `nil`, the built-in strategy runs. It estimates token count as
`chars ÷ 4` and triggers when usage exceeds `ratio * model.context_window`
(default ratio: 0.8). On trigger it calls the LLM with a structured prompt to
produce the summary; returns `:skip` on LLM failure.

## Custom compactors (sidecar)

Custom compactors live in the sidecar application. Implement the behaviour with
`use Planck.Agent.Hooks.Compactor`:

```elixir
defmodule MySidecar.Compactors.Builder do
  use Planck.Agent.Hooks.Compactor

  @impl true
  def compact(_model, messages) do
    case summarise(messages) do
      {:ok, text} ->
        summary_msg = Planck.Agent.Message.new({:custom, :summary}, [{:text, text}])
        kept = Enum.take(messages, -5)
        {:compact, summary_msg, kept}

      :error ->
        :skip
    end
  end

  @impl true
  def compact_timeout, do: 60_000

  defp summarise(messages) do
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

Declare the module by name in TEAM.json:

```json
{
  "type": "builder",
  "compactor": "MySidecar.Compactors.Builder"
}
```

planck_headless resolves the string to a module atom (after `:code.ensure_loaded`
on the sidecar node) and passes `compactor: MySidecar.Compactors.Builder` at
agent start time. No builder function is involved.

## Agent start opts

```elixir
Planck.Agent.start_link(
  id: "agent-1",
  model: model,
  compactor: MySidecar.Compactors.Builder,  # module atom, or nil for built-in
  sidecar_node: :"planck_sidecar@hostname"  # nil = local dispatch only
)
```

## API summary

```elixir
# Behaviour callbacks — implement in your custom compactor module.
@callback compact(model :: Model.t(), messages :: [Message.t()]) ::
            {:compact, summary :: Message.t(), kept :: [Message.t()]} | :skip
@callback compact_timeout() :: pos_integer()

# Dispatch — called by the agent runtime; not called directly by user code.
@spec Planck.Agent.Hooks.Compactor.compact(
        module  :: module() | nil,
        model   :: Planck.AI.Model.t(),
        messages :: [Message.t()],
        sidecar_node :: atom() | nil
      ) :: {:compact, Message.t(), [Message.t()]} | :skip
```
