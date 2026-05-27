defmodule Planck.Agent.Hooks.TurnEnd do
  @default_timeout_ms 30_000

  @moduledoc """
  Behaviour for post-turn reflection in `Planck.Agent`.

  Implement this behaviour in a sidecar module to inspect completed turns and
  take action — for example, writing a skill when a complex repeatable workflow
  is detected.

  ## Behaviour

  Use `use Planck.Agent.Hooks.TurnEnd` and override `reflect/2`:

      defmodule MySidecar.SkillReflector do
        use Planck.Agent.Hooks.TurnEnd

        @tool_threshold 5

        @impl true
        def reflect(agent_id, turn_messages) do
          # The implementation decides whether to act (e.g. threshold check).
          # Signal back via `Planck.Agent.inject_tool_result/3` if a skill was written.
          :ok
        end
      end

  ## Dispatch

  `Planck.Agent` fires `reflect/4` in a background `Task` after every `:turn_end`
  broadcast:

      Hooks.TurnEnd.reflect(state.turn_end_hook, state.id, turn_messages, state.sidecar_node)

  - `module: nil` — no-op.
  - `sidecar_node: nil` — calls `module.reflect/2` in-process.
  - `sidecar_node` set — calls via RPC; logs a warning on `:badrpc`.

  The default RPC timeout is #{@default_timeout_ms} ms; override `reflect_timeout/0`
  to declare a custom expected latency.
  """

  require Logger

  alias Planck.Agent.Message

  @doc """
  Inspect the completed turn and take action.

  Called after every turn. The implementation is responsible for any threshold
  checks or filtering. Must return `:ok`.
  """
  @callback reflect(
              agent_id :: String.t(),
              turn_messages :: [Message.t()]
            ) :: :ok

  @doc """
  RPC call timeout in milliseconds when this hook is invoked remotely.

  Defaults to 30,000 ms.
  """
  @callback reflect_timeout() :: pos_integer()

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour Planck.Agent.Hooks.TurnEnd

      @impl Planck.Agent.Hooks.TurnEnd
      def reflect(_agent_id, _turn_messages), do: :ok

      @impl Planck.Agent.Hooks.TurnEnd
      def reflect_timeout, do: Planck.Agent.Hooks.TurnEnd.default_timeout()

      defoverridable reflect: 2, reflect_timeout: 0
    end
  end

  @doc """
  Fire reflection for the completed turn.

  Returns `:ok` immediately when `module` is `nil`. Otherwise dispatches
  `module.reflect/2` locally or via RPC.
  """
  @spec reflect(module() | nil, String.t(), [Message.t()], atom() | nil) :: :ok
  def reflect(module, agent_id, turn_messages, sidecar_node)

  def reflect(nil, _agent_id, _turn_messages, _sidecar_node) do
    :ok
  end

  def reflect(module, agent_id, turn_messages, nil) do
    module.reflect(agent_id, turn_messages)
  end

  def reflect(module, agent_id, turn_messages, sidecar_node) do
    :rpc.call(sidecar_node, :code, :ensure_loaded, [module], 5_000)
    timeout = remote_reflect_timeout(module, sidecar_node)

    case :rpc.call(sidecar_node, module, :reflect, [agent_id, turn_messages], timeout) do
      {:badrpc, reason} ->
        Logger.warning(
          "[Planck.Agent.Hooks.TurnEnd] RPC failed (#{module}.reflect): #{inspect(reason)}"
        )

        :ok

      _ ->
        :ok
    end
  end

  @doc "Default RPC timeout used when a module omits `reflect_timeout/0`."
  @spec default_timeout() :: pos_integer()
  def default_timeout, do: @default_timeout_ms

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec remote_reflect_timeout(module(), atom()) :: pos_integer()
  defp remote_reflect_timeout(module, sidecar_node) do
    case :rpc.call(sidecar_node, module, :reflect_timeout, [], 5_000) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @default_timeout_ms
    end
  end
end
