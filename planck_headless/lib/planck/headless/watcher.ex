defmodule Planck.Headless.Watcher do
  @moduledoc """
  Watches the configured skill, team, and config directories for file changes
  and calls `ResourceStore.reload/0` so running agents pick up updated skill
  descriptions and configuration without restarting.

  ## Event source vs debounce

  `FileSystem` (backed by `inotify` on Linux, `FSEvents` on macOS, and
  `ReadDirectoryChangesW` on Windows) delivers OS-level file events — no
  polling. However, editors typically emit several events per save (write,
  chmod, rename) in quick succession, especially those that use atomic saves.
  A 300ms debounce timer is used so those bursts collapse into a single
  `ResourceStore.reload/0` call: each new event cancels the pending timer and
  starts a fresh one; the reload fires only after 300ms of silence.

  ## Watched paths

  Directories are derived from `Config` at startup:

  - `Config.skills_dirs!/0` — skill content directories
  - `Config.teams_dirs!/0` — team definition directories
  - Parent directories of `Config.config_files!/0` and `Config.env_files!/0`
    — so config and API-key changes are also detected

  Only directories that exist on disk are passed to `FileSystem`; missing
  ones are silently skipped. If no directories exist the watcher starts in a
  no-op mode.
  """

  use GenServer

  require Logger

  alias Planck.Headless.{Config, ResourceStore}

  @debounce_ms 300

  @doc "Start the file watcher under its supervisor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    dirs = watched_dirs()

    if dirs == [] do
      {:ok, %{watcher: nil, timer: nil}}
    else
      {:ok, watcher} = FileSystem.start_link(dirs: dirs)
      FileSystem.subscribe(watcher)
      Logger.debug("[Planck.Headless.Watcher] watching #{length(dirs)} director(ies)")
      {:ok, %{watcher: watcher, timer: nil}}
    end
  end

  @impl true
  def handle_info(event, state)

  def handle_info({:file_event, _pid, {_path, _events}}, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    timer = Process.send_after(self(), :reload, @debounce_ms)
    {:noreply, %{state | timer: timer}}
  end

  def handle_info(:reload, state) do
    ResourceStore.reload()
    {:noreply, %{state | timer: nil}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @spec watched_dirs() :: [Path.t()]
  defp watched_dirs do
    skill_dirs = Config.skills_dirs!() |> Enum.map(&Path.expand/1)
    team_dirs = Config.teams_dirs!() |> Enum.map(&Path.expand/1)

    # Watch the parent directories of config and env files so renames/writes
    # (common in editors) are detected even when the file itself doesn't exist yet.
    config_dirs =
      (Config.config_files!() ++ Config.env_files!())
      |> Enum.map(&(&1 |> Path.expand() |> Path.dirname()))

    (skill_dirs ++ team_dirs ++ config_dirs)
    |> Enum.uniq()
    |> Enum.filter(&File.dir?/1)
  end
end
