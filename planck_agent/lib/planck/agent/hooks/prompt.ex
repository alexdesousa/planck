defmodule Planck.Agent.Hooks.Prompt do
  @default_timeout_ms 5_000

  @moduledoc """
  Behaviour for injecting dynamic content into an agent's system prompt.

  Implement this behaviour in a sidecar module to inject per-session context
  (e.g. memory, project state) into the system prompt before every LLM turn.

  ## Behaviour

  Use `use Planck.Agent.Hooks.Prompt` and override either or both callbacks.
  Both default to returning `nil` (no injection).

      defmodule MySidecar.Hooks.Memory do
        use Planck.Agent.Hooks.Prompt

        @impl true
        def after_prompt(session_id) do
          case :ets.lookup(:memory, session_id) do
            [{^session_id, content}] -> content
            [] -> nil
          end
        end
      end

  ## Dispatch

  `Planck.Agent` stores the resolved hook module atom in state and calls
  `before_prompt/3` and `after_prompt/3` before every LLM turn:

      Hooks.Prompt.before_prompt(state.prompt_hook, state.session_id, state.sidecar_node)
      Hooks.Prompt.after_prompt(state.prompt_hook, state.session_id, state.sidecar_node)

  - `module: nil` — returns `nil` (no injection).
  - `sidecar_node: nil` — calls `module.prepend/1` / `module.append/1` in-process.
  - `sidecar_node` set — calls via RPC; returns `nil` on `:badrpc`.

  The default RPC timeout is #{@default_timeout_ms} ms; override `hook_timeout/0`
  to declare a custom expected latency.
  """

  require Logger

  @doc "Return text to inject before the base system prompt, or `nil` for no injection."
  @callback before_prompt(session_id :: String.t() | nil) :: String.t() | nil

  @doc "Return text to inject after all other system prompt sections, or `nil` for no injection."
  @callback after_prompt(session_id :: String.t() | nil) :: String.t() | nil

  @doc """
  RPC call timeout in milliseconds when this hook is invoked remotely.

  Defaults to #{@default_timeout_ms} ms.
  """
  @callback hook_timeout() :: pos_integer()

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour unquote(__MODULE__)

      @impl unquote(__MODULE__)
      def before_prompt(_session_id), do: nil

      @impl unquote(__MODULE__)
      def after_prompt(_session_id), do: nil

      @impl unquote(__MODULE__)
      def hook_timeout, do: unquote(__MODULE__).default_timeout()

      defoverridable before_prompt: 1, after_prompt: 1, hook_timeout: 0
    end
  end

  @doc "Default RPC timeout used when a hook module omits `hook_timeout/0`."
  @spec default_timeout() :: pos_integer()
  def default_timeout, do: @default_timeout_ms

  @doc """
  Call `module.before_prompt/1` and return the result, dispatching via RPC when
  `sidecar_node` is set. Returns `nil` when `module` is `nil` or on RPC failure.
  """
  @spec before_prompt(module() | nil, String.t() | nil, atom() | nil) :: String.t() | nil
  def before_prompt(module, session_id, sidecar_node)

  def before_prompt(nil, _session_id, _sidecar_node), do: nil

  def before_prompt(module, session_id, nil) do
    module.before_prompt(session_id)
  end

  def before_prompt(module, session_id, sidecar_node) do
    dispatch(module, :before_prompt, session_id, sidecar_node)
  end

  @doc """
  Call `module.after_prompt/1` and return the result, dispatching via RPC when
  `sidecar_node` is set. Returns `nil` when `module` is `nil` or on RPC failure.
  """
  @spec after_prompt(module() | nil, String.t() | nil, atom() | nil) :: String.t() | nil
  def after_prompt(module, session_id, sidecar_node)

  def after_prompt(nil, _session_id, _sidecar_node), do: nil

  def after_prompt(module, session_id, nil) do
    module.after_prompt(session_id)
  end

  def after_prompt(module, session_id, sidecar_node) do
    dispatch(module, :after_prompt, session_id, sidecar_node)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec dispatch(module(), :before_prompt | :after_prompt, String.t() | nil, atom()) ::
          String.t() | nil
  defp dispatch(module, callback, session_id, sidecar_node) do
    :rpc.call(sidecar_node, :code, :ensure_loaded, [module], @default_timeout_ms)
    timeout = remote_timeout(module, sidecar_node)

    case :rpc.call(sidecar_node, module, callback, [session_id], timeout) do
      {:badrpc, reason} ->
        Logger.warning(
          "[Planck.Agent.Hooks.Prompt] RPC failed (#{module}.#{callback}): #{inspect(reason)}"
        )

        nil

      result ->
        result
    end
  end

  @spec remote_timeout(module(), atom()) :: pos_integer()
  defp remote_timeout(module, sidecar_node) do
    case :rpc.call(sidecar_node, module, :hook_timeout, [], @default_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @default_timeout_ms
    end
  end
end
