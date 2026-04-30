# Planck.Headless

Headless core of the [Planck](../README.md) coding agent. A long-running OTP
application that owns configuration, loads resources (tools, skills, teams,
compactor) from the filesystem at startup, and manages session lifecycles.

UIs (`planck_tui`, `planck_web`) depend on this package; they are rendering
surfaces only and never call `planck_agent` directly.

See [`specs/planck-headless.md`](../specs/planck-headless.md) for the full design.

## Status

Phase 1A — package scaffold and `Planck.Headless.Config`. The ResourceStore,
team registry, and session lifecycle arrive in subsequent phases.

## Config

`Planck.Headless.Config` merges four sources, highest precedence first:

1. Environment variables — `PLANCK_*`
2. Project-local JSON — `.planck/config.json`
3. User-global JSON — `~/.planck/config.json`
4. Application config — `config :planck_headless, ...`

```elixir
config = Planck.Headless.config()
config.teams_dirs
# => [".planck/teams", "~/.planck/teams"]
```

See the module docs on `Planck.Headless.Config` for the full env-var table and
JSON schema.

## Development

```sh
PLANCK_LOCAL=true mix deps.get
PLANCK_LOCAL=true mix check
```

`PLANCK_LOCAL=true` resolves sibling packages (`planck_agent`) from disk
instead of Hex.
