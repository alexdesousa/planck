# Changelog

## Unreleased

- `Planck.Headless.Config` — Skogsra-backed resolved config. Three sources
  in priority order: env vars (`PLANCK_*`), `config :planck, ...` application
  config, hardcoded defaults. Values are cached via `preload/0` at boot and
  validated via `validate!/0`. `get/0` returns a fully-resolved
  `%Planck.Headless.Config{}` struct.
- `Planck.Headless.Config.PathList` — inline Skogsra type for
  colon-separated directory lists (`skills_dirs`, `tools_dirs`,
  `teams_dirs`).
- `Planck.Headless` top-level module with `config/0` entry point.
- Empty supervision tree; ResourceStore, team registry, and session
  lifecycle land in later phases.
- **Migration note**: this module is now the sole config home for the
  Planck stack. `Planck.Agent.Config` has been removed from `planck_agent`;
  env vars renamed from `PLANCK_AGENT_*` to `PLANCK_*`. Applications
  upgrading should rename their env vars or move their settings into
  `config :planck, ...` in `config/runtime.exs`.
