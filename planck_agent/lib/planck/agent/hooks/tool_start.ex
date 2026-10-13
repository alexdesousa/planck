defmodule Planck.Agent.Hooks.ToolStart do
  @default_timeout_ms 5_000

  @moduledoc """
  Behaviour for gating tool calls before they execute in `Planck.Agent`.

  Implement this behaviour in a sidecar module to allow, rewrite, deny, or
  park tool calls — for example, a safety gate over a destructive tool.

  ## Behaviour

  Use `use Planck.Agent.Hooks.ToolStart` and override `proceed/3`:

      defmodule MySidecar.Hooks.BashGate do
        use Planck.Agent.Hooks.ToolStart

        @impl true
        def proceed(_agent_id, "bash", %{"command" => "rm -rf /"} = _args) do
          {:deny, "destructive command"}
        end

        def proceed(_agent_id, _tool_name, _args), do: :ok
      end

  Return values:

  - `:ok` — run the call with its original arguments.
  - `{:proceed, new_args}` — run the call with rewritten arguments.
  - `{:deny, reason}` — skip execution; the agent sees an error containing
    `reason` plus a do-not-work-around notice.
  - `{:deny, reason, %{ui: ui_content}}` — same, plus a UI side effect
    served with the blocked error (e.g. an approval widget).
  - `{:await_approval, reason}` — park the call for human approval (handled
    by the approval loop); until approved it behaves like a deny.
  - `{:await_approval, reason, %{ui: ui_content}}` — same, plus a UI side
    effect served with the parked error.

  ## Dispatch

  `Planck.Agent` evaluates the gate synchronously inside `Turn.prepare_call/5`
  after argument validation, so schema-invalid calls never spend an evaluation:

      Hooks.ToolStart.proceed(state.hooks.tool_start, agent_id, tool_name, args, state.hooks.sidecar_node)

  - `module: nil` — proceeds with the original arguments (zero overhead).
  - `sidecar_node: nil` — calls `module.proceed/3` in-process.
  - `sidecar_node` set — calls via RPC; proceeds on `:badrpc`.

  The default RPC timeout is #{@default_timeout_ms} ms; override
  `proceed_timeout/0` to declare a custom expected latency.
  """

  require Logger

  @doc """
  Decide whether a tool call may run.

  See the moduledoc for the return shapes.
  """
  @callback proceed(
              agent_id :: String.t(),
              tool_name :: String.t(),
              args :: map()
            ) ::
              :ok
              | {:deny, String.t()}
              | {:await_approval, String.t()}

  @doc """
  RPC call timeout in milliseconds when this hook is invoked remotely.

  Defaults to #{@default_timeout_ms} ms.
  """
  @callback proceed_timeout() :: pos_integer()

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour unquote(__MODULE__)

      @impl unquote(__MODULE__)
      def proceed(_agent_id, _tool_name, _args), do: :ok

      @impl unquote(__MODULE__)
      def proceed_timeout, do: unquote(__MODULE__).default_timeout()

      defoverridable proceed: 3, proceed_timeout: 0
    end
  end

  @doc "Default RPC timeout used when a hook module omits `proceed_timeout/0`."
  @spec default_timeout() :: pos_integer()
  def default_timeout, do: @default_timeout_ms

  @typedoc false
  @type gate_result ::
          :ok
          | {:deny, String.t()}
          | {:await_approval, String.t()}

  @typedoc false
  @type blocked_verdict ::
          {:deny, String.t()}
          | {:await_approval, String.t()}

  @doc """
  Call `module.proceed/3` and return its result, dispatching via RPC when
  `sidecar_node` is set.

  Returns `:ok` when `module` is `nil`, on RPC failure, or on local
  exceptions (all fail-open with a warning where relevant). Anything else
  the hook returns is passed through untouched — the pipeline only matches
  the documented shapes, so any other value raises `CaseClauseError` in
  the calling process.
  """
  @spec proceed(module() | nil, String.t(), String.t(), map(), atom() | nil) :: gate_result()
  def proceed(module, agent_id, tool_name, args, sidecar_node)

  def proceed(nil, _agent_id, _tool_name, _args, _sidecar_node) do
    :ok
  end

  def proceed(module, agent_id, tool_name, args, nil)
      when is_atom(module) and
             is_binary(agent_id) and
             is_binary(tool_name) and
             is_map(args) do
    module.proceed(agent_id, tool_name, args)
  rescue
    e ->
      reason =
        "[Planck.Agent.Hooks.ToolStart] hook raised (#{module}.proceed): #{Exception.message(e)}, failing open"

      Logger.warning(reason)
      :ok
  end

  def proceed(module, agent_id, tool_name, args, sidecar_node)
      when is_atom(module) and is_binary(agent_id) and is_binary(tool_name) and is_map(args) do
    :rpc.call(sidecar_node, :code, :ensure_loaded, [module], @default_timeout_ms)
    timeout = remote_timeout(module, sidecar_node)

    case :rpc.call(sidecar_node, module, :proceed, [agent_id, tool_name, args], timeout) do
      {:badrpc, reason} ->
        Logger.warning(
          "[Planck.Agent.Hooks.ToolStart] RPC failed (#{module}.proceed): #{inspect(reason)}, failing open"
        )

        :ok

      result ->
        result
    end
  end

  @doc """
  Build the agent-visible error tuple for a blocked call.
  """
  @spec blocked_error(String.t()) :: {:error, String.t()}
  def blocked_error(reason)

  def blocked_error(reason) when is_binary(reason) do
    reason = "Tool call blocked: #{reason}\n\nDo not attempt to work around this block."
    {:error, reason}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec remote_timeout(module(), atom()) :: pos_integer()
  defp remote_timeout(module, sidecar_node) do
    case :rpc.call(sidecar_node, module, :proceed_timeout, [], @default_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @default_timeout_ms
    end
  end
end
