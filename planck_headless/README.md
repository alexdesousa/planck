# Planck.Headless

Headless core of the [Planck](../README.md) coding agent. A long-running OTP
application that owns configuration, loads resources (skills, teams, models)
at startup, manages session lifecycles, and optionally starts and manages a
sidecar OTP application that provides custom tools and compactors.

UIs (`planck_tui`, `planck_web`) depend on this package; they are rendering
surfaces only and never call `planck_agent` directly.

See [`specs/planck-headless.md`](../specs/planck-headless.md) for the full design.

## Session lifecycle

```elixir
# Start a session (default dynamic team, or pass template: "alias" for static)
{:ok, sid} = Planck.Headless.start_session()

# Send a prompt to the orchestrator
:ok = Planck.Headless.prompt(sid, "Refactor lib/app.ex to use a GenServer")

# Subscribe to events (planck_agent PubSub)
Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "session:#{sid}")

# Close — SQLite file retained for resume
:ok = Planck.Headless.close_session(sid)

# Resume by id or name — base team reconstructed, dynamically-spawned workers
# replayed from spawn_agent history, recovery context injected if interrupted
{:ok, sid2} = Planck.Headless.resume_session("crazy-mango")

# List all sessions (active + on disk)
Planck.Headless.list_sessions()
```

## Config

`Planck.Headless.Config` resolves from four sources (highest priority first):

1. Environment variables — `PLANCK_*`
2. JSON config files — `~/.planck/config.json` then `.planck/config.json`
3. Application config — `config :planck, ...`
4. Hardcoded defaults

```json
{
  "default_provider": "llama_cpp",
  "default_model":    "my-model",
  "models": [
    {
      "id":             "my-model",
      "provider":       "llama_cpp",
      "base_url":       "http://my-server:8080",
      "context_window": 32768
    }
  ]
}
```

See the module docs on `Planck.Headless.Config` for the full env-var table.

## Sidecars

A sidecar is a separate OTP application that provides custom tools and
compactors to planck_headless over distributed Erlang.

Configure the sidecar directory:

```json
{ "sidecar": ".planck/sidecar" }
```

Or via env var: `PLANCK_SIDECAR=.planck/sidecar`.

When the directory exists on disk, `Planck.Headless.SidecarManager` automatically:

1. Runs `mix deps.get` and `mix compile` in the sidecar directory.
2. Spawns the sidecar as a named Erlang node (`planck_sidecar@<host>`) via erlexec.
3. Discovers the sidecar's tools via `Planck.Agent.Sidecar.list_tools/0` on nodeup.
4. Makes those tools available to all new sessions through `ResourceStore`.

Subscribe to lifecycle events:

```elixir
Planck.Headless.SidecarManager.subscribe()

receive do
  {:connected, node} -> IO.puts("Sidecar ready: #{node}")
  {:disconnected, node} -> IO.puts("Sidecar gone: #{node}")
end
```

See `specs/sidecar.md` for the full design.

## Development

```sh
PLANCK_LOCAL=true mix deps.get
PLANCK_LOCAL=true mix check
```

Set `PLANCK_LOCAL=true` to resolve sibling packages (`planck_agent`, `planck_ai`)
from disk instead of Hex.

## Playground

See [`../playground/`](../playground/README.md) for a ready-to-run sandbox
against a local llamacpp or Ollama server.
