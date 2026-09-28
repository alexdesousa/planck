defmodule Planck.Agent.Hooks.Persistence do
  @default_timeout_ms 5_000

  @moduledoc """
  Behaviour and default implementation for conversation persistence in `Planck.Agent`.

  ## Behaviour

  Use `use Planck.Agent.Hooks.Persistence` to implement a custom persistence
  backend, in a sidecar or directly in your own app. Six callbacks are
  required — the first five are agent-scoped (an agent only ever touches its
  own history); the sixth, `load_session_messages/2`, is session-scoped, for
  callers outside any agent process that need every agent's history in one
  session, in original insertion order (e.g. a chat UI listing a whole
  conversation, orchestrator and workers together).

      defmodule MyApp.Persistence.Postgres do
        use Planck.Agent.Hooks.Persistence

        @impl true
        def persist_message(session_id, agent_id, message) do
          # write `message`, return it with its own row id set on `message.id`
        end

        @impl true
        def persist_usage(session_id, agent_id, usage), do: :ok

        @impl true
        def load_messages(session_id, agent_id, opts) do
          # return {:ok, [Message.t()]} in insertion order, or :error
        end

        @impl true
        def flush_unpersisted(session_id, agent_id, messages) do
          # write any of `messages` not yet persisted; :flushed | :noop
        end

        @impl true
        def truncate_after(session_id, message_id), do: :ok

        @impl true
        def load_session_messages(session_id, opts) do
          # return {:ok, [session_row()]} for every agent in the session,
          # interleaved by insertion order, or :error
        end
      end

  ## Dispatch

  `Planck.Agent` calls the first five (never the concrete
  `Planck.Agent.Session`/`SessionStore` modules directly) anywhere it needs to
  touch storage:

      Hooks.Persistence.persist_message(state.persistence, state.session_id, state.id, msg, state.sidecar_node)

  `load_session_messages/2` is never called by `Planck.Agent` itself — it
  exists for a caller like `planck_headless` (which knows a session's
  resolved persistence module from the team that materialized it) to hand a
  UI a cross-agent history without going through any single agent process, so
  it works for closed sessions too:

      Hooks.Persistence.load_session_messages(module, session_id, sidecar_node)

  Ephemeral agents (`session_id: nil`) never reach a persistence module at
  all — every agent-scoped dispatcher function no-ops before dispatching, the
  same way `Planck.Agent.SessionStore` does today.

  - `module: nil` — uses `Planck.Agent.Hooks.Persistence.Default`, the
    built-in SQLite-backed strategy (`Planck.Agent.Session`/`SessionStore`,
    wrapped to satisfy this behaviour). Not special-cased beyond this:
    `Default` satisfies the same behaviour a custom module would.
  - `module` set, `sidecar_node: nil` — calls the resolved module in-process.
  - `module` set, `sidecar_node` set — calls the module on the remote node
    via RPC; falls back to `Default` on `:badrpc` from any of the six calls.

  The default RPC timeout is #{@default_timeout_ms} ms; override
  `persistence_timeout/0` to declare a custom expected latency.
  """

  require Logger

  alias Planck.Agent.Hooks.Persistence.Default
  alias Planck.Agent.{Message, Usage}

  @typedoc "Options accepted by `load_messages/3` — currently just `strip_orphans:`."
  @type load_opts :: [strip_orphans: boolean()]

  @typedoc """
  A single persisted message as returned by `load_session_messages/2` —
  the same shape `Planck.Agent.Session.messages/2` rows already have, since
  callers like a chat UI need to know which agent said what, not just the
  message content.
  """
  @type session_row :: %{
          db_id: term(),
          agent_id: String.t(),
          message: Message.t(),
          inserted_at: integer()
        }

  @doc """
  Persist `message` and return it with its own row id set on `message.id`.
  """
  @callback persist_message(
              session_id :: String.t(),
              agent_id :: String.t(),
              message :: Message.t()
            ) ::
              Message.t()

  @doc "Persist accumulated usage and cost for the agent."
  @callback persist_usage(session_id :: String.t(), agent_id :: String.t(), usage :: Usage.t()) ::
              :ok

  @doc """
  Load message history for `agent_id` from `session_id`, in insertion order.

  Pass `strip_orphans: true` to remove a trailing assistant turn with
  unanswered tool calls — this repairs state after a crash.
  """
  @callback load_messages(session_id :: String.t(), agent_id :: String.t(), opts :: load_opts()) ::
              {:ok, [Message.t()]} | :error

  @doc """
  Persist any of `messages` not yet written to storage.

  Returns `:flushed` when at least one message was written, `:noop` when all
  messages were already persisted.
  """
  @callback flush_unpersisted(
              session_id :: String.t(),
              agent_id :: String.t(),
              messages :: [Message.t()]
            ) ::
              :flushed | :noop

  @doc """
  Delete all messages at or after `message_id`, across all agents in the
  session. Used when editing a previous message.
  """
  @callback truncate_after(session_id :: String.t(), message_id :: pos_integer()) ::
              :ok | {:error, term()}

  @doc """
  Load every agent's messages for `session_id`, interleaved by insertion
  order — the cross-agent history a chat UI displays, not any one agent's
  own view of it. Unlike the five callbacks above, this is never called by
  `Planck.Agent` itself; it's for a caller outside any agent process (see
  the moduledoc's "Dispatch" section).
  """
  @callback load_session_messages(session_id :: String.t(), opts :: keyword()) ::
              {:ok, [session_row()]} | :error

  @doc """
  RPC call timeout in milliseconds when this persistence module is invoked
  remotely. Defaults to #{@default_timeout_ms} ms.
  """
  @callback persistence_timeout() :: pos_integer()

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour unquote(__MODULE__)

      @impl unquote(__MODULE__)
      def persistence_timeout, do: unquote(__MODULE__).default_timeout()

      defoverridable persistence_timeout: 0
    end
  end

  @doc "Default RPC timeout used when a module omits `persistence_timeout/0`."
  @spec default_timeout() :: pos_integer()
  def default_timeout, do: @default_timeout_ms

  @doc """
  Persist `message`, dispatching to `module` (or `Default` when `nil`),
  locally or via `sidecar_node`. Returns `message` unchanged for ephemeral
  agents (`session_id: nil`).
  """
  @spec persist_message(module() | nil, String.t() | nil, String.t(), Message.t(), atom() | nil) ::
          Message.t()
  def persist_message(module, session_id, agent_id, message, sidecar_node)

  def persist_message(_module, nil, _agent_id, message, _sidecar_node) do
    message
  end

  def persist_message(nil, session_id, agent_id, message, sidecar_node) do
    persist_message(Default, session_id, agent_id, message, sidecar_node)
  end

  def persist_message(module, session_id, agent_id, %Message{} = message, nil)
      when is_atom(module) and
             is_binary(session_id) and
             is_binary(agent_id) do
    module.persist_message(session_id, agent_id, message)
  end

  def persist_message(module, session_id, agent_id, %Message{} = message, sidecar_node)
      when is_atom(module) and
             is_binary(session_id) and
             is_binary(agent_id) do
    dispatch(module, :persist_message, [session_id, agent_id, message], sidecar_node)
  end

  @doc """
  Persist `usage`, dispatching to `module` (or `Default` when `nil`), locally
  or via `sidecar_node`. No-op for ephemeral agents (`session_id: nil`).
  """
  @spec persist_usage(module() | nil, String.t() | nil, String.t(), Usage.t(), atom() | nil) ::
          :ok
  def persist_usage(module, session_id, agent_id, usage, sidecar_node)

  def persist_usage(_module, nil, _agent_id, _usage, _sidecar_node), do: :ok

  def persist_usage(nil, session_id, agent_id, %Usage{} = usage, sidecar_node)
      when is_binary(session_id) and is_binary(agent_id) do
    persist_usage(Default, session_id, agent_id, usage, sidecar_node)
  end

  def persist_usage(module, session_id, agent_id, %Usage{} = usage, nil)
      when is_atom(module) and
             is_binary(session_id) and
             is_binary(agent_id) do
    module.persist_usage(session_id, agent_id, usage)
  end

  def persist_usage(module, session_id, agent_id, %Usage{} = usage, sidecar_node)
      when is_atom(module) and
             is_binary(session_id) and
             is_binary(agent_id) do
    dispatch(module, :persist_usage, [session_id, agent_id, usage], sidecar_node)
  end

  @doc """
  Load message history, dispatching to `module` (or `Default` when `nil`),
  locally or via `sidecar_node`. Returns `:error` for ephemeral agents
  (`session_id: nil`) — there's nothing to load.
  """
  @spec load_messages(module() | nil, String.t() | nil, String.t(), load_opts(), atom() | nil) ::
          {:ok, [Message.t()]} | :error
  def load_messages(module, session_id, agent_id, opts, sidecar_node)

  def load_messages(_module, nil, _agent_id, _opts, _sidecar_node) do
    :error
  end

  def load_messages(nil, session_id, agent_id, opts, sidecar_node) do
    load_messages(Default, session_id, agent_id, opts, sidecar_node)
  end

  def load_messages(module, session_id, agent_id, opts, nil)
      when is_atom(module) and
             is_binary(session_id) and
             is_binary(agent_id) do
    module.load_messages(session_id, agent_id, opts)
  end

  def load_messages(module, session_id, agent_id, opts, sidecar_node)
      when is_atom(module) and
             is_binary(session_id) and
             is_binary(agent_id) do
    dispatch(module, :load_messages, [session_id, agent_id, opts], sidecar_node)
  end

  @doc """
  Flush any unpersisted `messages`, dispatching to `module` (or `Default`
  when `nil`), locally or via `sidecar_node`. Always `:noop` for ephemeral
  agents (`session_id: nil`).
  """
  @spec flush_unpersisted(
          module() | nil,
          String.t() | nil,
          String.t(),
          [Message.t()],
          atom() | nil
        ) ::
          :flushed | :noop
  def flush_unpersisted(module, session_id, agent_id, messages, sidecar_node)

  def flush_unpersisted(_module, nil, _agent_id, _messages, _sidecar_node) do
    :noop
  end

  def flush_unpersisted(nil, session_id, agent_id, messages, sidecar_node)
      when is_binary(session_id) and
             is_binary(agent_id) and
             is_list(messages) do
    flush_unpersisted(Default, session_id, agent_id, messages, sidecar_node)
  end

  def flush_unpersisted(module, session_id, agent_id, messages, nil)
      when is_atom(module) and
             is_binary(session_id) and
             is_binary(agent_id) and
             is_list(messages) do
    module.flush_unpersisted(session_id, agent_id, messages)
  end

  def flush_unpersisted(module, session_id, agent_id, messages, sidecar_node)
      when is_atom(module) and
             is_binary(session_id) and
             is_binary(agent_id) and
             is_list(messages) do
    dispatch(module, :flush_unpersisted, [session_id, agent_id, messages], sidecar_node)
  end

  @doc """
  Truncate the session, dispatching to `module` (or `Default` when `nil`),
  locally or via `sidecar_node`.
  """
  @spec truncate_after(module() | nil, String.t(), pos_integer(), atom() | nil) ::
          :ok | {:error, term()}
  def truncate_after(module, session_id, message_id, sidecar_node)

  def truncate_after(nil, session_id, message_id, sidecar_node)
      when is_binary(session_id) and
             is_integer(message_id) do
    truncate_after(Default, session_id, message_id, sidecar_node)
  end

  def truncate_after(module, session_id, message_id, nil)
      when is_atom(module) and
             is_binary(session_id) and
             is_integer(message_id) do
    module.truncate_after(session_id, message_id)
  end

  def truncate_after(module, session_id, message_id, sidecar_node) do
    dispatch(module, :truncate_after, [session_id, message_id], sidecar_node)
  end

  @doc """
  Load every agent's messages for `session_id`, dispatching to `module` (or
  `Default` when `nil`), locally or via `sidecar_node`. See the moduledoc —
  this is the one callback `Planck.Agent` itself never calls.
  """
  @spec load_session_messages(module() | nil, String.t(), atom() | nil) ::
          {:ok, [session_row()]} | :error
  def load_session_messages(module, session_id, sidecar_node)

  def load_session_messages(nil, session_id, sidecar_node)
      when is_binary(session_id) do
    load_session_messages(Default, session_id, sidecar_node)
  end

  def load_session_messages(module, session_id, nil)
      when is_atom(module) and
             is_binary(session_id) do
    module.load_session_messages(session_id, [])
  end

  def load_session_messages(module, session_id, sidecar_node)
      when is_atom(module) and
             is_binary(session_id) do
    dispatch(module, :load_session_messages, [session_id, []], sidecar_node)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Only reached once a remote module is actually configured — a `:badrpc`
  # falls back straight to Default (real, local, SQLite-backed persistence),
  # not to some neutral no-op: losing a persisted message on a transient RPC
  # failure is worse than losing a compaction pass, so this always still
  # writes somewhere.
  @spec dispatch(module(), atom(), list(), atom()) :: term()
  defp dispatch(module, fun, args, sidecar_node)

  defp dispatch(module, fun, args, sidecar_node)
       when is_atom(module) and
              is_atom(fun) do
    :rpc.call(sidecar_node, :code, :ensure_loaded, [module], @default_timeout_ms)
    timeout = remote_timeout(module, sidecar_node)

    case :rpc.call(sidecar_node, module, fun, args, timeout) do
      {:badrpc, reason} ->
        Logger.warning(
          "[Planck.Agent.Hooks.Persistence] RPC failed (#{module}.#{fun}): #{inspect(reason)}, falling back to Default"
        )

        apply(Default, fun, args)

      result ->
        result
    end
  end

  @spec remote_timeout(module(), atom()) :: pos_integer()
  defp remote_timeout(module, sidecar_node)

  defp remote_timeout(module, sidecar_node)
       when is_atom(module) do
    case :rpc.call(sidecar_node, module, :persistence_timeout, [], @default_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @default_timeout_ms
    end
  end
end
