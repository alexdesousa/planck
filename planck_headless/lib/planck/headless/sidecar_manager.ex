defmodule Planck.Headless.SidecarManager do
  @moduledoc """
  Manages the optional sidecar OTP application.

  At startup `SidecarManager` checks whether a sidecar directory is configured
  (`Config.sidecar!/0`). When it exists on disk, it:

  1. Runs `mix deps.get` and `mix compile` synchronously (fast-fail on error).
  2. Spawns the sidecar as a long-lived OS process via erlexec using:
     `elixir --sname planck_sidecar --cookie <cookie> -S mix run --no-halt`
     The following env var is injected so the sidecar can connect back:
     - `PLANCK_HEADLESS_NODE` — `Node.self()` stringified
  3. Monitors node connections. When the sidecar's Erlang node connects
     (name must begin with `"planck_sidecar"`), `SidecarManager` fetches the
     tool list via RPC and stores it in `ResourceStore`.
  4. On node-down or OS-process exit, clears tools from `ResourceStore`.

  ## Progress events

  Subscribe with `subscribe/0` to receive messages on the `"planck:sidecar"`
  PubSub topic. Events are one of:

  - `{:building, sidecar_dir}` — running `mix deps.get` / `mix compile`
  - `{:starting, sidecar_dir}` — OS process spawned, waiting for node
  - `{:connected, node}` — sidecar node is up and tools are loaded
  - `{:disconnected, node}` — sidecar node went down, tools cleared
  - `{:exited, reason}` — OS process exited unexpectedly
  - `{:error, step, reason}` — build/startup step failed
  """

  use GenServer

  require Logger

  alias Planck.Agent.Tool
  alias Planck.Headless.{Config, ResourceStore}

  @pubsub Planck.Agent.PubSub
  @topic "planck:sidecar"
  @sname "planck_sidecar"

  @type status :: :idle | :building | :starting | :connected | :failed

  @type state :: %{
          sidecar_dir: Path.t() | nil,
          sidecar_node: atom() | nil,
          os_pid: pos_integer() | nil,
          status: status()
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Start the SidecarManager under its supervisor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return the connected sidecar node name, or `nil` if not connected."
  @spec node() :: atom() | nil
  def node, do: GenServer.call(__MODULE__, :node)

  @doc "Return the current lifecycle status."
  @spec status() :: status()
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Subscribe the calling process to sidecar lifecycle events on `#{@topic}`."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @doc "Unsubscribe the calling process from sidecar lifecycle events."
  @spec unsubscribe() :: :ok
  def unsubscribe, do: Phoenix.PubSub.unsubscribe(@pubsub, @topic)

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    state = %{
      sidecar_dir: Config.sidecar!(),
      sidecar_node: nil,
      os_pid: nil,
      status: :idle
    }

    {:ok, state, {:continue, :maybe_start}}
  end

  @impl true
  def handle_continue(:maybe_start, %{sidecar_dir: nil} = state) do
    {:noreply, state}
  end

  def handle_continue(:maybe_start, state) do
    expanded = Path.expand(state.sidecar_dir)

    if File.dir?(expanded) do
      {:noreply, %{state | sidecar_dir: expanded}, {:continue, :build}}
    else
      {:noreply, state}
    end
  end

  def handle_continue(:build, state) do
    broadcast({:building, state.sidecar_dir})
    state = %{state | status: :building}

    with :ok <- run_step("deps.get", state.sidecar_dir),
         :ok <- run_step("compile", state.sidecar_dir) do
      {:noreply, state, {:continue, :spawn}}
    else
      {:error, step, reason} ->
        broadcast({:error, step, reason})
        Logger.error("[SidecarManager] #{step} failed in #{state.sidecar_dir}: #{reason}")
        {:noreply, %{state | status: :failed}}
    end
  end

  def handle_continue(:spawn, state) do
    case spawn_sidecar(state.sidecar_dir) do
      {:ok, os_pid} ->
        :net_kernel.monitor_nodes(true)
        broadcast({:starting, state.sidecar_dir})
        {:noreply, %{state | os_pid: os_pid, status: :starting}}

      {:error, reason} ->
        broadcast({:error, :spawn, reason})
        Logger.error("[SidecarManager] failed to spawn sidecar: #{inspect(reason)}")
        {:noreply, %{state | status: :failed}}
    end
  end

  @impl true
  def handle_call(:node, _from, state) do
    {:reply, state.sidecar_node, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_info({:nodeup, node}, %{sidecar_node: nil} = state) do
    if sidecar_node?(node) do
      tools = fetch_tools(node)
      ResourceStore.put_tools(tools)
      broadcast({:connected, node})
      {:noreply, %{state | sidecar_node: node, status: :connected}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:nodedown, node}, %{sidecar_node: node} = state) do
    ResourceStore.clear_tools()
    broadcast({:disconnected, node})
    Logger.warning("[SidecarManager] sidecar node #{node} disconnected")
    {:noreply, %{state | sidecar_node: nil, status: :starting}}
  end

  # erlexec monitor message — OS process exited
  def handle_info({:DOWN, _os_pid, :process, _pid, reason}, state) do
    ResourceStore.clear_tools()
    broadcast({:exited, reason})
    Logger.warning("[SidecarManager] sidecar OS process exited: #{inspect(reason)}")
    {:noreply, %{state | os_pid: nil, sidecar_node: nil, status: :failed}}
  end

  # Ignore nodeup/nodedown for other nodes we don't care about
  def handle_info({:nodeup, _node}, state), do: {:noreply, state}
  def handle_info({:nodedown, _node}, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec run_step(String.t(), Path.t()) :: :ok | {:error, String.t(), String.t()}
  defp run_step(task, dir) do
    opts = [:sync, :stdout, :stderr, cd: to_charlist(dir), env: env([])]

    case :exec.run("mix #{task}", opts) do
      {:ok, _} ->
        :ok

      {:error, details} ->
        output =
          (Keyword.get_values(details, :stdout) ++ Keyword.get_values(details, :stderr))
          |> List.flatten()
          |> Enum.join()

        {:error, task, output}
    end
  end

  @spec spawn_sidecar(Path.t()) :: {:ok, pos_integer()} | {:error, term()}
  defp spawn_sidecar(dir) do
    cookie =
      Node.get_cookie()
      |> Atom.to_string()

    headless_node =
      Node.self()
      |> Atom.to_string()
      |> to_charlist()

    extra = [{~c"PLANCK_HEADLESS_NODE", headless_node}]
    opts = [:monitor, cd: to_charlist(dir), env: env(extra)]

    cmd = "elixir --sname #{@sname} --cookie #{cookie} -S mix run --no-halt"

    case :exec.run(cmd, opts) do
      {:ok, _pid, os_pid} -> {:ok, os_pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec env([{charlist(), charlist()}]) :: [{charlist(), charlist()}]
  defp env(extra) do
    path =
      "PATH"
      |> System.get_env("")
      |> to_charlist()

    [{~c"PATH", path} | extra]
  end

  @spec sidecar_node?(atom()) :: boolean()
  defp sidecar_node?(node) do
    node
    |> Atom.to_string()
    |> String.starts_with?(@sname)
  end

  @default_tool_timeout_ms 300_000

  @spec fetch_tools(atom()) :: [Tool.t()]
  defp fetch_tools(node) do
    case :rpc.call(node, Planck.Agent.Sidecar, :list_tools, [], 10_000) do
      {:badrpc, reason} ->
        Logger.warning("[SidecarManager] list_tools RPC failed: #{inspect(reason)}")
        []

      ai_tools ->
        Enum.map(ai_tools, &wrap_tool(&1, node))
    end
  end

  @timeout_param %{
    "type" => "integer",
    "description" =>
      "Maximum milliseconds to wait for this tool call (default #{@default_tool_timeout_ms})."
  }

  @spec wrap_tool(Planck.AI.Tool.t(), atom()) :: Tool.t()
  defp wrap_tool(ai_tool, node) do
    Tool.new(
      name: ai_tool.name,
      description: ai_tool.description,
      parameters: inject_timeout_param(ai_tool.parameters),
      execute_fn: fn agent_id, args ->
        timeout = Map.get(args, "timeout_ms", @default_tool_timeout_ms)

        case :rpc.call(node, Planck.Agent.Sidecar, :execute_tool, [ai_tool.name, agent_id, args], timeout) do
          {:badrpc, reason} -> {:error, reason}
          result -> result
        end
      end
    )
  end

  @spec inject_timeout_param(map()) :: map()
  defp inject_timeout_param(%{"properties" => props} = parameters) do
    if Map.has_key?(props, "timeout_ms") do
      parameters
    else
      put_in(parameters, ["properties", "timeout_ms"], @timeout_param)
    end
  end

  defp inject_timeout_param(parameters), do: parameters

  @spec broadcast(term()) :: :ok
  defp broadcast(event) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, event)
  end
end
