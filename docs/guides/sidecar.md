# Planck Sidecars

A **sidecar** is a separate OTP application that extends Planck with custom tools
and compactors over distributed Erlang. It runs as a separate OS process and
connects back to the main Planck node automatically.

Use a sidecar when you need tools that:
- Maintain state across calls (GenServer)
- Integrate with external services (Telegram, Slack, databases, webhooks)
- Run long-lived background processes
- Require dependencies not available in the core

## Minimal scaffold

```
.planck/sidecar/
  mix.exs
  lib/
    my_sidecar/
      application.ex
      planck.ex         ← implements Planck.Agent.Sidecar
```

### mix.exs

```elixir
defmodule MySidecar.MixProject do
  use Mix.Project

  def project do
    [app: :my_sidecar, version: "0.1.0", elixir: "~> 1.19",
     start_permanent: true, deps: deps()]
  end

  def application do
    [mod: {MySidecar.Application, []}, extra_applications: [:logger]]
  end

  defp deps do
    [{:planck_agent, "~> 0.1"}]
  end
end
```

### application.ex

```elixir
defmodule MySidecar.Application do
  use Application

  @impl true
  def start(_type, _args) do
    headless = System.get_env("PLANCK_HEADLESS_NODE") |> String.to_atom()

    children = [
      {Task, fn -> Node.connect(headless) end}
      # Add your GenServers here
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

### planck.ex — tools

```elixir
defmodule MySidecar.Planck do
  use Planck.Agent.Sidecar

  @impl true
  def tools do
    [
      Planck.Agent.Tool.new(
        name: "notify_telegram",
        description: "Send a Telegram message to the configured chat.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "message" => %{"type" => "string", "description" => "Message to send"}
          },
          "required" => ["message"]
        },
        execute_fn: fn _agent_id, _id, %{"message" => msg} ->
          MySidecar.Telegram.send(msg)
        end
      )
    ]
  end
end
```

## Subscribing to session events (push model)

Instead of exposing a tool, a sidecar GenServer can subscribe to PubSub events
directly and act on them — useful for notifications when a phase completes:

```elixir
defmodule MySidecar.SessionMonitor do
  use GenServer

  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id)
  end

  def init(session_id) do
    Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "session:#{session_id}")
    {:ok, session_id}
  end

  def handle_info({:agent_event, :turn_end, %{message: msg}}, session_id) do
    MySidecar.Telegram.send("Phase complete: #{summarise(msg)}")
    {:noreply, session_id}
  end

  def handle_info(_event, state), do: {:noreply, state}
end
```

## Custom compactor

```elixir
defmodule MySidecar.Compactors.Summary do
  use Planck.Agent.Compactor

  @impl true
  def compact(_model, messages) do
    summary = Planck.Agent.Message.new({:custom, :summary}, [{:text, summarise(messages)}])
    {:compact, summary, Enum.take(messages, -5)}
  end

  @impl true
  def compact_timeout, do: 60_000
end
```

Assign it to an agent in `TEAM.json`:

```json
{ "type": "builder", "compactor": "MySidecar.Compactors.Summary" }
```

## Auto-reload in development

Because Planck calls sidecar tools via `:rpc.call/5`, the call always resolves
the **current loaded version** of the module on the sidecar node. If you reload
a module on the sidecar, the next tool call automatically picks up the new
implementation — no Planck restart needed.

Add `file_system` as a dev dependency and a small `Reloader` GenServer to watch
`lib/` for changes:

### OS requirements

`file_system` uses native OS APIs for file watching:

| OS | Backend | Requirement |
|---|---|---|
| Linux | `inotify` | `inotify-tools` — `sudo apt install inotify-tools` or `sudo dnf install inotify-tools` |
| macOS | `FSEvents` | Built into macOS — no extra packages needed |
| Windows | `ReadDirectoryChangesW` | Built into Windows — no extra packages needed |

### mix.exs (dev deps)

```elixir
defp deps do
  [
    {:planck_agent, "~> 0.1"},
    {:file_system, "~> 1.0", only: :dev}
  ]
end
```

### lib/my_sidecar/reloader.ex

```elixir
defmodule MySidecar.Reloader do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def init(_) do
    {:ok, watcher} = FileSystem.start_link(dirs: [Path.expand("lib")])
    FileSystem.subscribe(watcher)
    {:ok, watcher}
  end

  def handle_info({:file_event, _watcher, {path, events}}, state) do
    if :modified in events and String.ends_with?(to_string(path), ".ex") do
      IEx.Helpers.recompile()
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
```

### application.ex (start Reloader in dev)

```elixir
def start(_type, _args) do
  headless = System.get_env("PLANCK_HEADLESS_NODE") |> String.to_atom()

  children =
    [{Task, fn -> Node.connect(headless) end}] ++
      if Mix.env() == :dev, do: [MySidecar.Reloader], else: []

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

Run the sidecar with `MIX_ENV=dev mix run --no-halt`. Edit any module in `lib/`
and the change is live on the next tool call.

## Configuration

Enable the sidecar in `.planck/config.json`:

```json
{ "sidecar": ".planck/sidecar" }
```

Or via env var: `PLANCK_SIDECAR=.planck/sidecar`.

Planck will run `mix deps.get` and `mix compile` automatically on startup,
then spawn the sidecar process. Tools appear in all new sessions automatically.
