defmodule Planck.Agent.Hooks.TurnEnd do
  @default_timeout_ms 30_000
  @default_threshold 5

  @moduledoc """
  Behaviour for post-turn reflection in `Planck.Agent`.

  Implement this behaviour in a sidecar module to inspect completed turns and
  take action — for example, writing a skill when a complex repeatable workflow
  is detected.

  ## Behaviour

  Use `use Planck.Agent.Hooks.TurnEnd` and override the callbacks:

      defmodule MySidecar.Hooks.SkillReflector do
        use Planck.Agent.Hooks.TurnEnd

        @impl true
        def reflect_threshold, do: 5

        @impl true
        def reflect(agent_id, turn_messages, tool_call_count) do
          # Inspect turn_messages, decide whether to write a skill.
          # Write directly — no mini-agent needed.
          # Signal back via `Planck.Agent.inject_tool_result/3` if a skill was written.
          :ok
        end
      end

  ## Dispatch

  `Planck.Agent` fires `reflect/5` in a background `Task` after every `:turn_end`
  broadcast:

      Hooks.TurnEnd.reflect(state.turn_end_hook, state.id, turn_messages, tool_call_count, state.sidecar_node)

  The threshold check is the **first thing `reflect/5` does** — if
  `tool_call_count < module.reflect_threshold()`, it returns `:ok` immediately
  and nothing is dispatched. The background task is still spawned (to avoid
  blocking the agent), but it is very cheap on the common path.

  - `module: nil` — no-op.
  - `sidecar_node: nil` — calls `module.reflect/3` in-process.
  - `sidecar_node` set — calls via RPC; logs a warning on `:badrpc`.

  The default RPC timeout is #{@default_timeout_ms} ms; override `reflect_timeout/0`
  to declare a custom expected latency.
  """

  require Logger

  alias Planck.Agent.Message

  @doc """
  Inspect the completed turn and take action.

  Called after every turn where the tool call count derived from `turn_messages`
  meets or exceeds `reflect_threshold/0`. Must return `:ok`. Any side effects
  (writing skills, injecting messages) are the implementor's responsibility.

  The tool call count can be derived from `turn_messages` when needed:

      tool_call_count =
        turn_messages
        |> Enum.flat_map(& &1.content)
        |> Enum.count(&match?({:tool_call, _, _, _}, &1))
  """
  @callback reflect(
              agent_id :: String.t(),
              turn_messages :: [Message.t()]
            ) :: :ok

  @doc """
  Minimum number of tool calls in a turn to trigger `reflect/3`.

  Defaults to #{@default_threshold}. Override to tune sensitivity.
  """
  @callback reflect_threshold() :: non_neg_integer()

  @doc """
  RPC call timeout in milliseconds when this hook is invoked remotely.

  Defaults to #{@default_timeout_ms} ms.
  """
  @callback reflect_timeout() :: pos_integer()

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour unquote(__MODULE__)

      @impl unquote(__MODULE__)
      def reflect(_agent_id, _turn_messages), do: :ok

      @impl unquote(__MODULE__)
      def reflect_threshold, do: unquote(__MODULE__).default_threshold()

      @impl unquote(__MODULE__)
      def reflect_timeout, do: unquote(__MODULE__).default_timeout()

      defoverridable reflect: 2, reflect_threshold: 0, reflect_timeout: 0
    end
  end

  @doc "Default threshold used when a module omits `reflect_threshold/0`."
  @spec default_threshold() :: non_neg_integer()
  def default_threshold, do: @default_threshold

  @doc "Default RPC timeout used when a module omits `reflect_timeout/0`."
  @spec default_timeout() :: pos_integer()
  def default_timeout, do: @default_timeout_ms

  @doc """
  Fire reflection for the completed turn.

  Returns `:ok` immediately when `module` is `nil` or when the tool call count
  derived from `turn_messages` is below the module's threshold. Otherwise
  dispatches `module.reflect/2` locally or via RPC.
  """
  @spec reflect(module() | nil, String.t(), [Message.t()], atom() | nil) :: :ok
  def reflect(module, agent_id, turn_messages, sidecar_node)

  def reflect(nil, _agent_id, _turn_messages, _sidecar_node), do: :ok

  def reflect(module, agent_id, turn_messages, sidecar_node) do
    tool_call_count = count_tool_calls(turn_messages)
    threshold = get_threshold(module, sidecar_node)

    if tool_call_count >= threshold do
      do_reflect(module, agent_id, turn_messages, sidecar_node)
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec count_tool_calls([Message.t()]) :: non_neg_integer()
  defp count_tool_calls(messages) do
    messages
    |> Enum.flat_map(& &1.content)
    |> Enum.count(&match?({:tool_call, _, _, _}, &1))
  end

  @spec do_reflect(module(), String.t(), [Message.t()], atom() | nil) :: :ok
  defp do_reflect(module, agent_id, turn_messages, nil) do
    module.reflect(agent_id, turn_messages)
  end

  defp do_reflect(module, agent_id, turn_messages, sidecar_node) do
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

  @spec get_threshold(module(), atom() | nil) :: non_neg_integer()
  defp get_threshold(module, nil) do
    module.reflect_threshold()
  end

  defp get_threshold(module, sidecar_node) do
    case :rpc.call(sidecar_node, module, :reflect_threshold, [], 5_000) do
      n when is_integer(n) and n >= 0 -> n
      _ -> @default_threshold
    end
  end

  @spec remote_reflect_timeout(module(), atom()) :: pos_integer()
  defp remote_reflect_timeout(module, sidecar_node) do
    case :rpc.call(sidecar_node, module, :reflect_timeout, [], 5_000) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @default_timeout_ms
    end
  end
end
