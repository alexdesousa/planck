# Compactors

A compactor is an optional hook that `Planck.Agent` calls before each LLM turn
to manage context length. When context grows too long, the compactor summarises
older messages into a single checkpoint, keeping only recent messages verbatim.

## The `Planck.Agent.Hooks.Compactor` behaviour

```elixir
@callback compact?(
            state   :: Planck.Agent.t(),
            context :: Planck.AI.Context.t(),
            recent  :: [Planck.Agent.Message.t()]
          ) :: boolean()

@callback compact(
            state :: Planck.Agent.t(),
            context :: Planck.AI.Context.t(),
            recent :: [Planck.Agent.Message.t()]
          ) ::
            {:compact,
              summary_msg :: Planck.Agent.Message.t(),
              kept :: [Planck.Agent.Message.t()]}
            | :skip

@callback compact_timeout() :: pos_integer()
```

> Breaking change from the single-callback shape: `compact/3` used to be the
> only required callback, and the caller had no way to know in advance
> whether a given dispatch would actually compact. A custom compactor must
> now also implement `compact?/3` — a cheap decision (must not itself do
> anything slow, e.g. no LLM call) that the dispatcher checks first. `compact/3`,
> the potentially slow part, is only ever called when `compact?/3` returns
> `true`. For a simple port of an existing custom compactor, `compact?/3` can
> just re-run whatever check `compact/3` used to do up front, returning a
> boolean instead of `:skip`.

- **Input**: `state` (the agent's full state — model, messages, etc., for
  anything a custom strategy might need beyond the two below), `context` (the
  request Planck is about to send if it doesn't compact), and `recent` (the
  messages since the last summary checkpoint — the "active window").
- **`compact?/3`**: `true`/`false` — whether `compact/3` would actually do
  anything right now.
- **`:skip`** (from `compact/3`): leave messages unchanged and proceed. A
  compactor is free to still return `:skip` here even after saying `true` to
  `compact?/3` (e.g. nothing old enough left worth summarizing).
- **`{:compact, summary_msg, kept}`**: replace the active window with `summary_msg`
  followed by `kept`. `summary_msg` should have role `{:custom, :summary}` to be
  stored as a checkpoint in the session and recognized by future compaction passes.

`use Planck.Agent.Hooks.Compactor` injects a default 120 000 ms `compact_timeout/0`.

## Dispatch

`Hooks.Compactor.compact/4` is the single dispatch entry point:

```elixir
Planck.Agent.Hooks.Compactor.compact(state, context, recent, opts)
```

`opts` is `[on_compacting: (-> any()), on_compacted: (-> any())]` — both
zero-arity, both optional. The dispatcher, not any compactor implementation,
calls `compact?/3` first and, only if it returns `true`, wraps the call to
`compact/3` with these two closures (`on_compacting` before, `on_compacted`
after, regardless of what `compact/3` itself then returns). `Planck.Agent`
uses this to broadcast `:compacting`/`:compacted` PubSub events so the UI can
show a progress indicator for the duration of the call — accurate for any
compactor, without `Planck.Agent` needing to predict the outcome, and without
any compactor implementation needing to know about PubSub topics or event
shapes at all.

- `state.compactor: nil` → runs the built-in LLM-based compactor locally.
- `state.compactor: MyMod` + `state.sidecar_node: nil` → calls `MyMod.compact?/3`,
  then, only if `true`, `MyMod.compact/3`, locally.
- `state.compactor: MyMod` + `state.sidecar_node: node` → `:rpc.call` to the
  sidecar node for both calls (same two-call shape); falls back to the
  built-in compactor if either RPC fails (`:badrpc`).

## Built-in compactor

When `state.compactor` is `nil`, the built-in strategy runs:

**Trigger** — estimates token count via `Planck.AI.Context.estimate_tokens/1`
(system prompt + tool schemas + messages, `chars ÷ 4` per part); fires when
usage exceeds `0.8 × model.context_window`. Estimating from the whole
`context` rather than `recent` alone matters — a sizeable system prompt or
tool list can itself account for a large share of the window, and a
messages-only estimate would judge the conversation to have more headroom
than it actually does.

**Keep-recent** — walks backwards from the most recent message, accumulating
messages until their total estimated tokens exceed `0.1 × model.context_window`
(the "keep budget"). At least one message is always kept even if it alone
exceeds the budget. Everything older than the kept window is passed to the
summariser.

**Summary** — calls the LLM with a structured prompt asking for a concise
summary of the old messages. The summary is stored as a `{:custom, :summary}`
message prepended to the kept window. Returns `:skip` on LLM failure so the
agent can continue without compaction.

This LLM call is synchronous — it blocks the agent's `GenServer` for its
duration, the same as any other turn. `on_compacting`/`on_compacted` exist
precisely so the UI reflects that blocking instead of appearing to hang.

## Custom compactors (sidecar)

Custom compactors live in the sidecar application. Implement the behaviour with
`use Planck.Agent.Hooks.Compactor`:

```elixir
defmodule MySidecar.Compactors.Builder do
  use Planck.Agent.Hooks.Compactor

  @impl true
  def compact?(state, context, _recent) do
    Planck.AI.Context.estimate_tokens(context) >= state.model.context_window * 0.8
  end

  @impl true
  def compact(_state, _context, recent) do
    case summarise(recent) do
      {:ok, text} ->
        summary_msg = Planck.Agent.Message.new({:custom, :summary}, [{:text, text}])
        kept = Enum.take(recent, -5)
        {:compact, summary_msg, kept}

      :error ->
        :skip
    end
  end

  @impl true
  def compact_timeout, do: 60_000

  defp summarise(recent) do
    text = Enum.map_join(recent, "\n", &extract_text/1)
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
@callback compact?(
            state :: Planck.Agent.t(),
            context :: Planck.AI.Context.t(),
            recent :: [Message.t()]
          ) :: boolean()
@callback compact(
            state :: Planck.Agent.t(),
            context :: Planck.AI.Context.t(),
            recent :: [Message.t()]
          ) :: {:compact, summary :: Message.t(), kept :: [Message.t()]} | :skip
@callback compact_timeout() :: pos_integer()

# Dispatch — called by the agent runtime; not called directly by user code.
@spec Planck.Agent.Hooks.Compactor.compact(
        state :: Planck.Agent.t(),
        context :: Planck.AI.Context.t(),
        recent :: [Message.t()],
        opts :: [on_compacting: (-> any()), on_compacted: (-> any())]
      ) :: {:compact, Message.t(), [Message.t()]} | :skip
```
