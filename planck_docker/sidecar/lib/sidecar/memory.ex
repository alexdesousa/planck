defmodule Sidecar.Memory do
  @moduledoc """
  Short-term agent memory — implements `Planck.Agent.Hooks.Prompt`.

  Injects per-agent memory into the system prompt before every LLM turn.
  Memory is stored in Typesense (`short_term_memory` collection, one document
  per agent keyed by `"team_name:agent_name"`) and cached in ETS for fast
  non-blocking reads.

  ## Lifecycle

  - `after_prompt(session_id)` — reads from ETS. On a cache miss (first turn
    of a new session) it queries Typesense by agent key and warms the cache.
  - `:compacted` event on `"planck:sessions"` — refreshes ETS from Typesense,
    picking up any `update_memory` calls made during the session.
  - `update_memory` tool — agent writes condensed facts; persists to Typesense
    and updates ETS immediately.

  ## TEAM.json

      { "prompt_hook": "Sidecar.Memory" }
  """

  use GenServer

  use Planck.Agent.Hooks.Prompt

  require Logger

  @table :sidecar_memory
  @retry_delay 2_000

  # ---------------------------------------------------------------------------
  # Planck.Agent.Hooks.Prompt callbacks
  # ---------------------------------------------------------------------------

  @impl Planck.Agent.Hooks.Prompt
  def before_prompt(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, content}] -> content
      [] -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Starts the memory store under its supervisor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Write `content` as the memory for `agent_key` (`"team_name:agent_name"`).

  Upserts to Typesense and updates the ETS cache for `session_id`.
  Called by the `update_memory` sidecar tool.
  """
  @spec write(String.t(), String.t() | nil, String.t()) :: :ok | {:error, String.t()}
  def write(agent_key, session_id, content) do
    GenServer.call(__MODULE__, {:write, agent_key, session_id, content})
  end

  @doc false
  def flush, do: GenServer.call(__MODULE__, :flush)

  @doc "Return the current memory content for `agent_key`, or `nil` if none exists."
  @spec current(String.t()) :: String.t() | nil
  def current(agent_key) do
    case Sidecar.Typesense.get(Sidecar.Config.memory_collection!(), agent_key) do
      {:ok, %{"content" => content}} -> content
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}, {:continue, :init_collection}}
  end

  @impl GenServer
  def handle_continue(event, state)

  def handle_continue(:init_collection, state) do
    if Sidecar.Typesense.ready?() do
      schema = %{
        name: Sidecar.Config.memory_collection!(),
        fields: [
          %{name: "agent_key", type: "string", facet: true},
          %{name: "content", type: "string"}
        ]
      }

      Sidecar.Typesense.ensure_collection(schema)
      Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "planck:sessions")
      Logger.info("[Sidecar.Memory] ready")
      {:noreply, state}
    else
      Logger.debug("[Sidecar.Memory] Typesense not ready — retrying in #{@retry_delay}ms")
      Process.send_after(self(), :retry_init, @retry_delay)
      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_call(message, from, state)

  def handle_call(:flush, _from, state), do: {:reply, :ok, state}

  def handle_call({:write, agent_key, session_id, content}, _from, state) do
    doc = %{id: agent_key, agent_key: agent_key, content: content}

    case Sidecar.Typesense.upsert(Sidecar.Config.memory_collection!(), doc) do
      :ok ->
        if session_id, do: :ets.insert(@table, {session_id, content})
        {:reply, :ok, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl GenServer
  def handle_info(message, state)

  def handle_info(:retry_init, state) do
    {:noreply, state, {:continue, :init_collection}}
  end

  def handle_info(
        {:agent_event, :compacted,
         %{session_id: session_id, agent_name: agent_name, team_name: team_name}},
        state
      ) do
    agent_key = "#{team_name}:#{agent_name}"

    case Sidecar.Typesense.get(Sidecar.Config.memory_collection!(), agent_key) do
      {:ok, %{"content" => content}} -> :ets.insert(@table, {session_id, content})
      :not_found -> :ok
      {:error, reason} -> Logger.warning("[Sidecar.Memory] refresh failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info(
        {:agent_event, :turn_end,
         %{session_id: session_id, agent_name: agent_name, team_name: team_name}},
        state
      ) do
    # Warm ETS on the first turn of a session (lazy load).
    case :ets.lookup(@table, session_id) do
      [_] ->
        :ok

      [] ->
        agent_key = "#{team_name}:#{agent_name}"

        case Sidecar.Typesense.get(Sidecar.Config.memory_collection!(), agent_key) do
          {:ok, %{"content" => content}} -> :ets.insert(@table, {session_id, content})
          _ -> :ok
        end
    end

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
