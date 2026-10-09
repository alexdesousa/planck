defmodule Planck.Agent.Hooks.TurnStart do
  @default_timeout_ms 30_000

  @moduledoc """
  Behaviour for observing turn starts in `Planck.Agent`.

  Implement this behaviour in a sidecar module to observe when a new LLM turn
  begins — for example, memory warmup or metrics. Observer-only: unlike
  `Planck.Agent.Hooks.Prompt` (the sole synchronous prompt injector), this
  hook can neither block the turn nor inject prompt content.

  ## Behaviour

  Use `use Planck.Agent.Hooks.TurnStart` and override `notify/2`:

      defmodule MySidecar.Hooks.Metrics do
        use Planck.Agent.Hooks.TurnStart

        @impl true
        def notify(agent_id, session_id) do
          MySidecar.Metrics.count_turn(agent_id, session_id)
          :ok
        end
      end

  ## Dispatch

  `Planck.Agent` fires `notify/4` in a background `Task` alongside every
  `:turn_start` broadcast:

      Hooks.TurnStart.notify(state.hooks.turn_start, state.identity.id, state.identity.session_id, state.hooks.sidecar_node)

  - `module: nil` — no-op.
  - `sidecar_node: nil` — calls `module.notify/2` in-process.
  - `sidecar_node` set — calls via RPC; logs a warning on `:badrpc`.

  The default RPC timeout is #{@default_timeout_ms} ms; override
  `notify_timeout/0` to declare a custom expected latency.
  """

  require Logger

  @doc """
  Observe that a new turn started for `agent_id` in `session_id`.

  Observer-only — the return value is always `:ok` and the turn proceeds
  regardless. Must return `:ok`.
  """
  @callback notify(
              agent_id :: String.t(),
              session_id :: String.t() | nil
            ) :: :ok

  @doc """
  RPC call timeout in milliseconds when this hook is invoked remotely.

  Defaults to #{@default_timeout_ms} ms.
  """
  @callback notify_timeout() :: pos_integer()

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour unquote(__MODULE__)

      @impl unquote(__MODULE__)
      def notify(_agent_id, _session_id), do: :ok

      @impl unquote(__MODULE__)
      def notify_timeout, do: unquote(__MODULE__).default_timeout()

      defoverridable notify: 2, notify_timeout: 0
    end
  end

  @doc "Default RPC timeout used when a module omits `notify_timeout/0`."
  @spec default_timeout() :: pos_integer()
  def default_timeout, do: @default_timeout_ms

  @doc """
  Fire notification that a turn started.

  Returns `:ok` immediately when `module` is `nil`. Otherwise dispatches
  `module.notify/2` locally or via RPC. Never raises.
  """
  @spec notify(module() | nil, String.t(), String.t() | nil, atom() | nil) :: :ok
  def notify(module, agent_id, session_id, sidecar_node)

  def notify(nil, _agent_id, _session_id, _sidecar_node) do
    :ok
  end

  def notify(module, agent_id, session_id, nil)
      when is_atom(module) and is_binary(agent_id) do
    module.notify(agent_id, session_id)
  end

  def notify(module, agent_id, session_id, sidecar_node)
      when is_atom(module) and is_binary(agent_id) do
    :rpc.call(sidecar_node, :code, :ensure_loaded, [module], 5_000)
    timeout = remote_notify_timeout(module, sidecar_node)

    case :rpc.call(sidecar_node, module, :notify, [agent_id, session_id], timeout) do
      {:badrpc, reason} ->
        Logger.warning(
          "[Planck.Agent.Hooks.TurnStart] RPC failed (#{module}.notify): #{inspect(reason)}"
        )

        :ok

      _ ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec remote_notify_timeout(module(), atom()) :: pos_integer()
  defp remote_notify_timeout(module, sidecar_node) do
    case :rpc.call(sidecar_node, module, :notify_timeout, [], 5_000) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @default_timeout_ms
    end
  end
end
