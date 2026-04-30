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

`Planck.Headless.Config` resolves three sources in priority order:

1. Environment variables — `PLANCK_*`
2. Application config — `config :planck, <key>, ...`
3. Hardcoded defaults

```elixir
config = Planck.Headless.config()
config.teams_dirs
# => [".planck/teams", "~/.planck/teams"]
```

Values are cached via `preload/0` at boot; change a value at runtime by
calling `Application.put_env/3` followed by the Skogsra-generated
`reload_<key>/0` helper.

See the module docs on `Planck.Headless.Config` for the full env-var table.

## Development

```sh
PLANCK_LOCAL=true mix deps.get
PLANCK_LOCAL=true mix check
```

`PLANCK_LOCAL=true` resolves sibling packages (`planck_agent`) from disk
instead of Hex.
