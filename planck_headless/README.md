# Planck.Headless

Headless core of the [Planck](../README.md) coding agent. A long-running OTP
application that owns configuration, loads resources (tools, skills, teams,
compactor, models) at startup, and manages session lifecycles.

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
