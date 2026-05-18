defmodule Sidecar.Reloader do
  @moduledoc """
  Dev-only GenServer that watches `lib/` for changes and recompiles the sidecar.

  Uses a 300 ms debounce so editors that emit multiple events per save
  (write + chmod + rename) only trigger one recompile. Only started when
  `MIX_ENV=dev`.
  """

  use GenServer

  @debounce_ms 300

  @doc "Starts the reloader and registers it under its module name."
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(options)

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(options)

  def init(_options) do
    {:ok, watcher} = FileSystem.start_link(dirs: [Path.expand("lib")])
    FileSystem.subscribe(watcher)
    {:ok, %{watcher: watcher, timer: nil}}
  end

  @impl true
  def handle_info(event, state)

  def handle_info({:file_event, _watcher, {path, _events}}, state) do
    if String.ends_with?(to_string(path), ".ex") do
      if state.timer, do: Process.cancel_timer(state.timer)
      timer = Process.send_after(self(), :recompile, @debounce_ms)
      {:noreply, %{state | timer: timer}}
    else
      {:noreply, state}
    end
  end

  def handle_info(:recompile, state) do
    apply(IEx.Helpers, :recompile, [])
    {:noreply, %{state | timer: nil}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
