defmodule Planck.Agent.PromptHook do
  @default_timeout_ms 5_000

  @moduledoc """
  Behaviour for injecting dynamic content into an agent's system prompt.

  Implement this behaviour in a sidecar module to inject context (e.g. memory,
  project state) into the system prompt before every LLM turn, keyed by session.

  ## Behaviour

  Use `use Planck.Agent.PromptHook` and override either or both callbacks.
  Both default to returning `nil` (no injection).

      defmodule MySidecar.Hooks.Memory do
        use Planck.Agent.PromptHook

        @impl true
        def append(session_id) do
          case :ets.lookup(:memory, session_id) do
            [{^session_id, content}] -> content
            [] -> nil
          end
        end
      end

  ## Building hook closures

  `build/2` converts a module name string into the two closures expected by
  `Planck.Agent` (`system_prompt_prepend_fn` and `system_prompt_append_fn`).
  Pass `session_id:` so the callbacks can look up per-session state, and
  `sidecar_node:` when the module lives in a remote sidecar.

      hook_opts = Planck.Agent.PromptHook.build("MySidecar.Hooks.Memory",
        session_id:   session_id,
        sidecar_node: SidecarManager.node()
      )
      # Returns [system_prompt_prepend_fn: fn, system_prompt_append_fn: fn]

      start_opts = AgentSpec.to_start_opts(spec, hook_opts ++ [on_compact: fn, ...])

  When `name` is `nil` or both `sidecar_node:` and `session_id:` produce no closures,
  `build/2` returns `[]` — `Keyword.merge` with an empty list is a no-op, so
  callers need no nil-guard.

  ## RPC behaviour

  When `sidecar_node:` is provided, `build/2` preloads the module on the remote
  node and each closure dispatches via `:rpc.call/5`. On RPC failure, the closure
  returns `nil` (no injection) — it never raises. The default RPC timeout is
  #{@default_timeout_ms} ms; override `hook_timeout/0` to declare a custom value.
  """

  require Logger

  @doc """
  Return text to prepend before the base system prompt, or `nil` for no injection.
  """
  @callback prepend(session_id :: String.t() | nil) :: String.t() | nil

  @doc """
  Return text to append after all other system-prompt sections, or `nil` for no injection.
  """
  @callback append(session_id :: String.t() | nil) :: String.t() | nil

  @doc """
  RPC call timeout in milliseconds when this hook is invoked remotely.

  Defaults to #{@default_timeout_ms} ms. Override to declare a custom expected
  latency — the module knows its own logic better than any caller default.
  """
  @callback hook_timeout() :: pos_integer()

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour unquote(__MODULE__)

      @impl unquote(__MODULE__)
      def prepend(_session_id), do: nil

      @impl unquote(__MODULE__)
      def append(_session_id), do: nil

      @impl unquote(__MODULE__)
      def hook_timeout, do: unquote(__MODULE__).default_timeout()

      defoverridable prepend: 1, append: 1, hook_timeout: 0
    end
  end

  @doc "Default RPC timeout used when a hook module omits `hook_timeout/0`."
  @spec default_timeout() :: pos_integer()
  def default_timeout, do: @default_timeout_ms

  @typedoc """
  Options accepted by `build/2`.

  - `:session_id` — passed as-is to `prepend/1` and `append/1`
  - `:sidecar_node` — node name of a connected sidecar (enables remote dispatch)
  """
  @type opts :: [
          session_id: String.t() | nil,
          sidecar_node: atom() | nil
        ]

  @doc """
  Build `system_prompt_prepend_fn` and `system_prompt_append_fn` closures.

  Returns a keyword list with `:system_prompt_prepend_fn` and
  `:system_prompt_append_fn` — ready to be spread into `AgentSpec.to_start_opts/2`
  overrides. Returns `[]` when `name` is `nil`.

  ## Examples

      # Local module:
      hook_opts = PromptHook.build("MyApp.Hooks.Memory", session_id: session_id)

      # Remote sidecar:
      hook_opts = PromptHook.build("MySidecar.Hooks.Memory",
        session_id:   session_id,
        sidecar_node: :planck_sidecar@host
      )

      AgentSpec.to_start_opts(spec, hook_opts ++ [on_compact: fn, team_id: id])

  """
  @spec build(String.t() | nil, opts()) :: keyword()
  def build(name, opts)

  def build(nil, _opts) do
    []
  end

  def build(name, opts) when is_binary(name) and is_list(opts) do
    session_id = Keyword.get(opts, :session_id)
    sidecar_node = Keyword.get(opts, :sidecar_node)
    module = :"Elixir.#{name}"

    [
      system_prompt_prepend_fn: make_fn(module, :prepend, session_id, sidecar_node),
      system_prompt_append_fn: make_fn(module, :append, session_id, sidecar_node)
    ]
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec make_fn(module(), :prepend | :append, String.t() | nil, atom() | nil) ::
          (-> String.t() | nil)
  defp make_fn(module, callback, session_id, sidecar_node)

  defp make_fn(module, callback, session_id, nil) do
    fn -> apply(module, callback, [session_id]) end
  end

  defp make_fn(module, callback, session_id, sidecar_node) do
    :rpc.call(sidecar_node, :code, :ensure_loaded, [module], @default_timeout_ms)
    timeout = remote_timeout(module, sidecar_node)

    fn ->
      case :rpc.call(sidecar_node, module, callback, [session_id], timeout) do
        {:badrpc, reason} ->
          Logger.warning(
            "[Planck.Agent.PromptHook] RPC failed (#{module}.#{callback}): #{inspect(reason)}"
          )

          nil

        result ->
          result
      end
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
