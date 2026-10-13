defmodule Planck.Agent.Hooks.ToolEnd do
  @default_timeout_ms 5_000

  @moduledoc """
  Behaviour for transforming tool results before they reach the agent in
  `Planck.Agent`.

  Implement this behaviour in a sidecar module to rewrite result text or
  attach UI side effects — for example, tagging a blocked call's error with
  the approval widget.

  ## Behaviour

  Use `use Planck.Agent.Hooks.ToolEnd` and override `transform/4`. The
  default is the identity (returns `result` unchanged):

      defmodule MySidecar.Hooks.ApprovalTagger do
        use Planck.Agent.Hooks.ToolEnd

        @impl true
        def transform(_agent_id, _tool_name, _args, {:error, reason} = _result) do
          {:error, reason, %{ui: %{kind: :text, text: "approval required"}}}
        end

        def transform(_agent_id, _tool_name, _args, result), do: result
      end

  Return values mirror the tool result type, now including the error triple:

  - `{:ok, text}` / `{:ok, text, %{ui: ui_content()}}`
  - `{:error, reason}` / `{:error, reason, %{ui: ui_content()}}`

  ## Dispatch

  `Planck.Agent` applies the transform synchronously inside
  `Turn.prepare_call/5` after execution (and after the loop-nudge):

      Hooks.ToolEnd.transform(state.hooks.tool_end, agent_id, tool_name, args, result, state.hooks.sidecar_node)

  - `module: nil` — identity (zero overhead).
  - `sidecar_node: nil` — calls `module.transform/4` in-process.
  - `sidecar_node` set — calls via RPC; returns `result` unchanged on `:badrpc`.

  The default RPC timeout is #{@default_timeout_ms} ms; override
  `transform_timeout/0` to declare a custom expected latency.
  """

  require Logger

  alias Planck.Agent.Tool

  @doc """
  Transform a tool result before it reaches the agent.

  Defaults to the identity. Must return a well-formed tool result, including
  the error triple form.
  """
  @callback transform(
              agent_id :: String.t(),
              tool_name :: String.t(),
              args :: map(),
              result ::
                {:ok, String.t()}
                | {:ok, String.t(), %{ui: Tool.ui_content()}}
                | {:error, String.t()}
                | {:error, String.t(), %{ui: Tool.ui_content()}}
            ) ::
              {:ok, String.t()}
              | {:ok, String.t(), %{ui: Tool.ui_content()}}
              | {:error, String.t()}
              | {:error, String.t(), %{ui: Tool.ui_content()}}

  @doc """
  RPC call timeout in milliseconds when this hook is invoked remotely.

  Defaults to #{@default_timeout_ms} ms.
  """
  @callback transform_timeout() :: pos_integer()

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour unquote(__MODULE__)

      @impl unquote(__MODULE__)
      def transform(_agent_id, _tool_name, _args, result), do: result

      @impl unquote(__MODULE__)
      def transform_timeout, do: unquote(__MODULE__).default_timeout()

      defoverridable transform: 4, transform_timeout: 0
    end
  end

  @doc "Default RPC timeout used when a hook module omits `transform_timeout/0`."
  @spec default_timeout() :: pos_integer()
  def default_timeout, do: @default_timeout_ms

  @typedoc false
  @type tool_result ::
          {:ok, String.t()}
          | {:ok, String.t(), %{ui: Tool.ui_content()}}
          | {:error, String.t()}
          | {:error, String.t(), %{ui: Tool.ui_content()}}

  @doc """
  Call `module.transform/4` and return the result, dispatching via RPC when
  `sidecar_node` is set.

  Returns `result` unchanged when `module` is `nil`, on RPC failure, on local
  exceptions, or on unexpected return values (all fail-open with a warning
  where relevant).
  """
  @spec transform(module() | nil, String.t(), String.t(), map(), tool_result(), atom() | nil) ::
          tool_result()
  def transform(module, agent_id, tool_name, args, result, sidecar_node)

  def transform(nil, _agent_id, _tool_name, _args, result, _sidecar_node), do: result

  def transform(module, agent_id, tool_name, args, result, nil)
      when is_atom(module) and is_binary(agent_id) and is_binary(tool_name) and is_map(args) do
    try do
      module.transform(agent_id, tool_name, args, result) |> normalize(module, result)
    rescue
      e ->
        Logger.warning(
          "[Planck.Agent.Hooks.ToolEnd] hook raised (#{module}.transform): #{Exception.message(e)}, keeping result"
        )

        result
    end
  end

  def transform(module, agent_id, tool_name, args, result, sidecar_node)
      when is_atom(module) and is_binary(agent_id) and is_binary(tool_name) and is_map(args) do
    :rpc.call(sidecar_node, :code, :ensure_loaded, [module], @default_timeout_ms)
    timeout = remote_timeout(module, sidecar_node)

    case :rpc.call(
           sidecar_node,
           module,
           :transform,
           [agent_id, tool_name, args, result],
           timeout
         ) do
      {:badrpc, reason} ->
        Logger.warning(
          "[Planck.Agent.Hooks.ToolEnd] RPC failed (#{module}.transform): #{inspect(reason)}, keeping result"
        )

        result

      transformed ->
        normalize(transformed, module, result)
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec normalize(term(), module(), tool_result()) :: tool_result()
  defp normalize({:ok, text}, _module, _fallback) when is_binary(text), do: {:ok, text}

  defp normalize({:ok, text, %{ui: _} = extra}, _module, _fallback) when is_binary(text),
    do: {:ok, text, extra}

  defp normalize({:error, reason}, _module, _fallback) when is_binary(reason),
    do: {:error, reason}

  defp normalize({:error, reason, %{ui: _} = extra}, _module, _fallback) when is_binary(reason) do
    {:error, reason, extra}
  end

  defp normalize(other, module, fallback) do
    Logger.warning(
      "[Planck.Agent.Hooks.ToolEnd] unexpected return (#{module}.transform): #{inspect(other)}, keeping result"
    )

    fallback
  end

  @spec remote_timeout(module(), atom()) :: pos_integer()
  defp remote_timeout(module, sidecar_node) do
    case :rpc.call(sidecar_node, module, :transform_timeout, [], @default_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @default_timeout_ms
    end
  end
end
