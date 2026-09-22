defmodule Planck.Agent.Hooks.Compactor.Default do
  @moduledoc """
  Built-in `Planck.Agent.Hooks.Compactor` implementation.

  Used whenever `state.compactor` is `nil` — see `Planck.Agent.Hooks.Compactor`'s
  own moduledoc for the dispatch rules. Not special-cased by the dispatcher in
  any other way: this module satisfies the same behaviour a sidecar-hosted
  custom compactor would, and could be named explicitly via `AgentSpec.compactor`
  too.

  ## Strategy

  The messages since the last summary checkpoint are split into a recency
  floor (always kept verbatim — mirrors the "at least the last message is
  always kept" invariant) and an older bucket. The older bucket is summarized
  as one plain-text block by a real, ephemeral `Planck.Agent` — not asked for
  structured per-message output. An earlier version of this asked the
  delegate for per-message keep/drop verdicts as JSON; that turned out to be
  the wrong shape for a compactor that has to work with whatever model is
  configured, not a specific one: producing well-formed JSON with correct
  message-id references is a much less reliable task for a weak/small model
  than writing a plain summary is, and a compactor that only works with
  capable models defeats its own "works everywhere" purpose. Per-message
  relevance judgment still has a natural home — a fast classifier-style
  model whose native output already is one answer per item — just not here.

  The delegate agent has no `team_id` (invisible to `list_team`, which only
  enumerates registered team members), no `session_id` (nothing is persisted
  for it), and no tools — a pure text-in/text-out summarization call. It is
  `Process.monitor/1`-ed, not `Process.link/1`-ed: a crashing delegate must
  degrade to `:skip`, not crash the compacting agent (worker or orchestrator).
  It is always stopped before this module returns, on every exit path.

  `compact/3` still blocks the compacting agent's own `GenServer` for the
  duration — that's deliberate, unchanged from before (see
  `Planck.Agent.Hooks.Compactor`'s moduledoc on `on_compacting`/`on_compacted`).
  What must *not* happen inside that `GenServer` callback is a raw `receive`
  waiting on the delegate's PubSub events: the delegate is a real
  `Planck.Agent` broadcasting `:turn_start`/`:text_delta`/`:usage_delta`/etc,
  not just `:turn_end`, and any of those left unmatched by a receive done
  directly in the compacting agent's own process would sit in *its* mailbox,
  corrupting its own `handle_info/2` dispatch once this call returns. So the
  actual subscribe/prompt/await sequence runs inside a dedicated,
  `async_nolink` `Task` instead — its mailbox and PubSub subscription are
  simply discarded when it exits, regardless of what's left in it, the same
  isolation `Tools.call_agent`'s own await loop already relies on for this
  exact reason. `compact/3` blocks on awaiting that task, not on a receive
  in its own process.
  """

  use Planck.Agent.Hooks.Compactor

  require Logger

  alias Planck.Agent
  alias Planck.Agent.Message
  alias Planck.AI.Context

  @default_ratio 0.8
  @keep_ratio 0.1

  @delegate_system_prompt """
  Summarize the conversation below to reduce context length.
  Your summary must:
  - Describe completed work and resolved decisions briefly
  - State clearly what is currently being worked on and the most recent requests
  - Preserve any key facts, file paths, decisions, or constraints still relevant
  - Be written as context for an AI agent continuing this conversation

  Prioritize recency — the active task and latest requests take priority over earlier history.
  """

  @impl true
  def compact?(%Agent{} = state, %Context{} = context, _recent) do
    threshold = trunc(state.model.context_window * @default_ratio)
    Context.estimate_tokens(context) >= threshold
  end

  @impl true
  def compact(%Agent{model: model} = state, %Context{} = _context, recent) do
    keep_budget = trunc(model.context_window * @keep_ratio)
    {old, kept} = split_by_token_budget(recent, keep_budget)

    with [_ | _] = to_summarize <-
           Enum.reject(old, &match?(%Message{role: {:custom, :summary}}, &1)),
         {:ok, text} <- spawn_delegate(state, to_summarize) do
      summary_msg = Message.new({:custom, :summary}, [{:text, text}])
      {:compact, summary_msg, kept}
    else
      [] ->
        :skip

      {:error, reason} ->
        message = "[Planck.Agent.Hooks.Compactor.Default] delegate failed: #{inspect(reason)}"
        Logger.warning(message)
        :skip
    end
  end

  # ---------------------------------------------------------------------------
  # Delegate agent
  # ---------------------------------------------------------------------------

  @spec spawn_delegate(Agent.t(), [Message.t()]) :: {:ok, String.t()} | {:error, term()}
  defp spawn_delegate(state, to_summarize)

  defp spawn_delegate(%Agent{model: model}, to_summarize) do
    start_opts = [
      id: generate_id(),
      model: model,
      system_prompt: @delegate_system_prompt,
      tools: []
    ]

    case DynamicSupervisor.start_child(Planck.Agent.AgentSupervisor, {Planck.Agent, start_opts}) do
      {:ok, pid} ->
        await_delegate_task(pid, to_summarize)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec generate_id() :: String.t()
  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  @spec await_delegate_task(pid(), [Message.t()]) ::
          {:ok, String.t()}
          | {:error, term()}
  defp await_delegate_task(pid, to_summarize)

  defp await_delegate_task(pid, to_summarize) when is_pid(pid) do
    try do
      do_await_delegate_task(pid, to_summarize)
    after
      if Process.alive?(pid), do: Agent.stop(pid)
    end
  end

  # The subscribe/prompt/await sequence runs entirely inside a dedicated,
  # disposable Task — never directly in the compacting agent's own GenServer
  # process, even though compact/3 itself still blocks that process (see
  # moduledoc: the blocking is deliberate, only the *mixing* was the bug).
  # The delegate is a real Planck.Agent — it broadcasts :turn_start,
  # :text_delta, :usage_delta, etc. too, not just :turn_end. A raw `receive`
  # done directly in the compacting GenServer's own callback would leave any
  # of those it doesn't match sitting in *that* process's mailbox, corrupting
  # its own handle_info/2 dispatch once this call returns. A Task's mailbox
  # (and its PubSub subscription, tied to its own pid) is discarded entirely
  # when it exits, regardless of what's left in it, the same isolation
  # `Tools.call_agent`'s own await loop already relies on for this reason.
  # `async_nolink`, not `Task.async/1` — a crash in the task must not
  # propagate to (crash) the compacting agent, the same reasoning that ruled
  # out `Process.link/1` for the delegate agent itself.
  @spec do_await_delegate_task(pid(), [Message.t()]) ::
          {:ok, String.t()}
          | {:error, term()}
  defp do_await_delegate_task(pid, to_summarize) do
    task =
      Task.Supervisor.async_nolink(Planck.Agent.TaskSupervisor, fn ->
        run_delegate(pid, to_summarize)
      end)

    case Task.yield(task, compact_timeout()) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:delegate_task_exit, reason}}
      nil -> {:error, :timeout}
    end
  end

  @spec run_delegate(pid(), [Message.t()]) :: {:ok, String.t()} | {:error, term()}
  defp run_delegate(pid, to_summarize) do
    ref = Process.monitor(pid)
    :ok = Agent.subscribe(pid)
    :ok = Agent.prompt(pid, format_history(to_summarize))
    await_delegate(ref)
  end

  # Drains every non-terminal event from the delegate (:turn_start,
  # :text_delta, :usage_delta, ...) rather than returning on the first
  # unmatched message — the delegate's own turn keeps running regardless of
  # whether this loop is watching, so anything short of :turn_end/:error/
  # :DOWN just means "not done yet," not "unexpected."
  @spec await_delegate(reference()) :: {:ok, String.t()} | {:error, term()}
  defp await_delegate(ref) do
    receive do
      {:agent_event, :turn_end, %{message: msg}} ->
        Process.demonitor(ref, [:flush])

        case extract_text(msg.content) do
          "" -> {:error, :empty_response}
          text -> {:ok, text}
        end

      {:agent_event, :error, %{reason: reason}} ->
        Process.demonitor(ref, [:flush])
        {:error, reason}

      {:agent_event, _other_type, _payload} ->
        await_delegate(ref)

      {:DOWN, ^ref, :process, _pid, reason} ->
        {:error, {:delegate_down, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Formatting
  # ---------------------------------------------------------------------------

  @spec format_history([Message.t()]) :: String.t()
  defp format_history(messages) do
    Enum.map_join(messages, "\n\n", fn %Message{role: role, content: content} ->
      "#{format_role(role)}: #{extract_text(content)}"
    end)
  end

  @spec format_role(Message.role()) :: String.t()
  defp format_role(role)
  defp format_role(:user), do: "User"
  defp format_role(:assistant), do: "Assistant"
  defp format_role(:tool_result), do: "Tool result"
  defp format_role({:custom, kind}), do: kind |> Atom.to_string() |> String.capitalize()

  @spec extract_text([Planck.AI.Message.content_part()]) :: String.t()
  defp extract_text(content) do
    content
    |> Enum.flat_map(fn
      {:text, text} -> [text]
      {:tool_result, _id, value} -> [value]
      _ -> []
    end)
    |> IO.iodata_to_binary()
  end

  # ---------------------------------------------------------------------------
  # Recency floor
  # ---------------------------------------------------------------------------

  # Walk from the tail, accumulating messages until the token budget is exceeded.
  # Always keeps at least the last message even if it alone exceeds the budget.
  @spec split_by_token_budget([Message.t()], non_neg_integer()) ::
          {[Message.t()], [Message.t()]}
  defp split_by_token_budget(messages, budget) do
    {kept, _} =
      messages
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn msg, {kept, total} ->
        cost = messages_tokens([msg])
        new_total = total + cost

        if new_total <= budget or kept == [] do
          {:cont, {[msg | kept], new_total}}
        else
          {:halt, {kept, total}}
        end
      end)

    Enum.split(messages, length(messages) - length(kept))
  end

  @spec messages_tokens([Message.t()]) :: non_neg_integer()
  defp messages_tokens(messages) do
    Context.estimate_tokens(%Context{messages: Message.to_ai_messages(messages)})
  end
end
