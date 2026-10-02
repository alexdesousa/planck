defmodule Planck.Agent.Hooks.Compactor do
  @moduledoc """
  Behaviour and default implementation for context compaction in `Planck.Agent`.

  ## Behaviour

  Use `use Planck.Agent.Hooks.Compactor` to implement a custom compaction strategy
  in a sidecar. Two callbacks are required, `compact?/3` and `compact/3`;
  `compact_timeout/0` has a default of #{600_000} ms.

      defmodule MySidecar.Compactors.Builder do
        use Planck.Agent.Hooks.Compactor

        @impl true
        def compact?(state, context, _recent) do
          Planck.AI.Context.estimate_tokens(context) >= state.model.context_window * 0.8
        end

        @impl true
        def compact(_state, _context, recent, _args) do
          summary = Message.new({:custom, :summary}, [{:text, summarise(recent)}])
          kept    = Enum.take(recent, -5)
          {:compact, summary, kept}
        end

        @impl true
        def compact_timeout, do: 60_000
      end

  `compact?/3` is checked first; `compact/4` — the potentially slow part, an
  LLM call for the built-in strategy — is only ever called when it returns
  `true`. Splitting these means the *dispatcher* (`compact/4` below), not
  each implementation, can wrap the slow part with a progress announcement
  correctly for any compactor, without needing to predict anything — see
  "Why a separate compact?/3, and why the dispatcher wraps compact/4" below.

  ## Dispatch

  `Planck.Agent` calls `compact/4` before every LLM turn:

      Hooks.Compactor.compact(state, context, recent, opts)

  - `state` — the full agent state (model, compactor, sidecar_node, ...).
  - `context` — the `Planck.AI.Context.t()` built for `recent` (system prompt,
    tool schemas, and `recent` itself, already estimated as one whole — see
    `Planck.AI.Context.estimate_tokens/1`). Passed through rather than just
    `recent` alone so a *custom* compactor (typically running on a sidecar
    node, which has no other way to see the agent's system prompt or tool
    list) can make an informed decision too, not only the built-in one.
  - `recent` — `state.messages` since the last `{:custom, :summary}`
    checkpoint (or all of them, if there isn't one yet).
  - `opts` — `:on_compacting` and `:on_compacted`, both zero-arity functions,
    both optional. `:args` — a map (default `%{prompt: nil}`) forwarded to
    the compactor's `compact/4` callback as its 4th parameter; used by
    `/compact [prompt]` to steer the summarization. Called by *this dispatch
    function*, around `compact/4` — never by a `compact/4` implementation
    itself, which never receives `opts` at all. `Planck.Agent` supplies
    `on_compacting`/`on_compacted` so the UI can be told compaction is in
    progress without any compactor needing to know anything about
    `Planck.Agent`'s own PubSub topics or event shapes.

  - `state.compactor: nil` — uses `Planck.Agent.Hooks.Compactor.Default`, the
    built-in strategy (see its own moduledoc). Not special-cased beyond this:
    `Default` satisfies the same behaviour a custom module would.
  - `state.compactor` set, `state.sidecar_node: nil` — calls `module.compact?/3`,
    then, only if that's `true`, `module.compact/3`, in-process.
  - `state.compactor` set, `state.sidecar_node` set — calls the module on the
    remote node via RPC (same two-call shape); falls back to `Default` on
    `:badrpc` from either call.

  ## Why a separate `compact?/3`, and why the dispatcher wraps `compact/3`

  `Planck.Agent` calls this dispatcher on *every* turn, and can't know in
  advance whether a given call will actually compact — that decision
  belongs to the compactor, and for a custom one, its criteria are opaque to
  `Planck.Agent` entirely. Broadcasting "compacting" unconditionally around
  every call (clearing it right after) would flash it on every ordinary
  turn, not just the rare one that actually compacts. Predicting the
  outcome from `Planck.Agent`'s side (e.g. reapplying the built-in ratio)
  would only be accurate for the built-in compactor. Splitting the decision
  (`compact?/3`, always cheap — no LLM call for the built-in strategy) from
  the work (`compact/3`, potentially slow) lets the dispatcher check the
  decision first and only announce progress around the part that's
  genuinely slow — accurate for any compactor, without `Planck.Agent`
  needing to predict anything or any compactor needing to call back into
  `Planck.Agent` itself.
  """

  require Logger

  alias Planck.Agent
  alias Planck.Agent.Hooks.Compactor.Default
  alias Planck.Agent.Message
  alias Planck.AI.Context

  # Local model prefill can take a long time, especially for a large
  # summarization prompt — 120s was too tight for real self-hosted use, not
  # just a theoretical concern.
  @default_compact_timeout_ms 600_000

  @typedoc false
  @type compact_opt ::
          {:on_compacting, (-> any())}
          | {:on_compacted, (-> any())}
          | {:args, %{prompt: String.t() | nil}}
          | {:force, boolean()}
          | {:timeout, non_neg_integer()}

  @typedoc """
  `:on_compacting`/`:on_compacted` — both zero-arity, both optional (neither
  given just means nothing tells the UI compaction is in progress, not an
  error). `:args` — a map forwarded to the compactor's `compact/4` callback;
  defaults to `%{prompt: nil}` when absent (auto-compaction). `:force` — when
  `true`, bypasses `compact?/3` and calls `compact/4` directly; used by the
  `/compact` slash command.
  """
  @type compact_opts :: [compact_opt()]

  @typedoc false
  @type compact_args :: %{prompt: String.t() | nil}

  @typedoc false
  @type compact_result :: :skip | {:compact, Message.t(), [Message.t()]}

  @doc """
  Cheap decision: would `compact/3` actually do anything right now? Must not
  itself do anything slow (no LLM call) — see the moduledoc for why.
  """
  @callback compact?(state :: Agent.t(), context :: Context.t(), recent :: [Message.t()]) ::
              boolean()

  @doc """
  Compact the conversation. Only ever called when `compact?/3` (checked by
  the dispatcher, not called here) already returned `true`, or directly by
  the forced `/compact` slash-command path (which bypasses `compact?/3`).

  `args` is a map that may contain `:prompt` — a user-supplied string (from
  `/compact [prompt]`) that can steer the summarization. `nil` when absent
  (auto-compaction).

  Return `{:compact, summary_msg, kept}` to replace older messages with a
  summary, or `:skip` to leave the list unchanged — a compactor is free to
  still decide against compacting here even after saying `true` to
  `compact?/3` (e.g. nothing old enough left worth summarizing).
  """
  @callback compact(
              state :: Agent.t(),
              context :: Context.t(),
              recent :: [Message.t()],
              args :: compact_args()
            ) :: compact_result()

  @doc """
  RPC call timeout in milliseconds when this compactor is invoked remotely.

  Defaults to #{@default_compact_timeout_ms} ms.
  """
  @callback compact_timeout() :: pos_integer()

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour unquote(__MODULE__)

      @impl unquote(__MODULE__)
      def compact_timeout, do: unquote(__MODULE__).default_compact_timeout()

      defoverridable compact_timeout: 0
    end
  end

  @doc "Default RPC timeout used when a compactor module omits `compact_timeout/0`."
  @spec default_compact_timeout() :: pos_integer()
  def default_compact_timeout, do: @default_compact_timeout_ms

  @doc """
  Dispatch compaction for the given agent state, its built request context,
  and the messages since the last summary — see this module's own moduledoc.

  Returns `:skip` or `{:compact, summary_msg, kept}`.
  """
  @spec compact(Agent.t(), Context.t(), [Message.t()], compact_opts()) :: compact_result()
  def compact(state, context, recent, opts \\ [])

  def compact(%Agent{compactor: nil} = state, %Context{} = context, recent, opts) do
    compact(%{state | compactor: Default}, context, recent, opts)
  end

  def compact(
        %Agent{compactor: module, sidecar_node: nil} = state,
        %Context{} = context,
        recent,
        opts
      ) do
    args = Keyword.get(opts, :args, %{prompt: nil})
    force = Keyword.get(opts, :force, false)

    if force or module.compact?(state, context, recent) do
      with_notice(opts, fn -> module.compact(state, context, recent, args) end)
    else
      :skip
    end
  end

  def compact(
        %Agent{compactor: module, sidecar_node: sidecar_node} = state,
        %Context{} = context,
        recent,
        opts
      ) do
    :rpc.call(sidecar_node, :code, :ensure_loaded, [module], 5_000)

    opts = add_remote_timeout(opts, module, sidecar_node)

    timeout = opts[:timeout]
    args = opts[:args] || %{prompt: nil}
    force = Keyword.get(opts, :force, false)

    if force do
      with_notice(opts, fn ->
        do_compact_remote(state, context, recent, args, timeout)
      end)
    else
      compact_remote(state, context, recent, opts)
    end
  end

  @spec compact_remote(Agent.t(), Context.t(), [Message.t()], compact_opts()) :: compact_result()
  defp compact_remote(state, context, recent, opts)

  defp compact_remote(
         %Agent{compactor: module, sidecar_node: sidecar_node} = state,
         %Context{} = context,
         recent,
         opts
       ) do
    timeout = opts[:timeout]
    args = opts[:args] || %{prompt: nil}

    case :rpc.call(sidecar_node, module, :compact?, [state, context, recent], timeout) do
      {:badrpc, reason} ->
        Logger.warning(
          "[Planck.Agent.Hooks.Compactor] RPC failed (#{module}): #{inspect(reason)}, falling back to local"
        )

        compact(%{state | sidecar_node: nil, compactor: nil}, context, recent, opts)

      true ->
        with_notice(opts, fn ->
          do_compact_remote(state, context, recent, args, timeout)
        end)

      false ->
        :skip
    end
  end

  # Fires on_compacting (default: no-op) before calling fun, on_compacted
  # (default: no-op) after — regardless of what fun returns, including a
  # further internal :skip, since on_compacting already announced work was
  # starting and on_compacted must still fire to clear that.
  @spec with_notice(compact_opts(), (-> compact_result())) :: compact_result()
  defp with_notice(opts, fun) do
    on_compacting = Keyword.get(opts, :on_compacting, fn -> :ok end)
    on_compacted = Keyword.get(opts, :on_compacted, fn -> :ok end)

    on_compacting.()
    result = fun.()
    on_compacted.()
    result
  end

  # Only reached once the remote module's own compact?/3 already said
  # `true` — a :badrpc here falls back straight to Default, not back through
  # compact?/3 again: compact?/3's criteria belongs to the remote module, and
  # we already have a `true` from it — re-deciding via a different
  # compactor's rules here would be a confusing outcome after already
  # committing to compacting.
  @spec do_compact_remote(Agent.t(), Context.t(), [Message.t()], compact_args(), pos_integer()) ::
          compact_result()
  defp do_compact_remote(
         %Agent{sidecar_node: sidecar_node, compactor: module} = state,
         %Context{} = context,
         recent,
         args,
         timeout
       ) do
    case :rpc.call(sidecar_node, module, :compact, [state, context, recent, args], timeout) do
      {:badrpc, reason} ->
        Logger.warning(
          "[Planck.Agent.Hooks.Compactor] RPC failed (#{module}): #{inspect(reason)}, falling back to local"
        )

        Default.compact(state, context, recent, args)

      result ->
        result
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec add_remote_timeout(compact_opts(), module(), atom()) :: compact_opts()
  defp add_remote_timeout(opts, module, sidecar_node) do
    case :rpc.call(sidecar_node, module, :compact_timeout, [], 5_000) do
      timeout when is_integer(timeout) and timeout > 0 ->
        Keyword.put(opts, :timeout, timeout)

      _ ->
        Keyword.put(opts, :timeout, @default_compact_timeout_ms)
    end
  end
end
