# Changelog

## Unreleased

- `Planck.Headless.Config` — Skogsra-backed resolved config; merges
  `~/.planck/config.json` and `.planck/config.json` into the application env
  before Skogsra resolves each key; env vars (`PLANCK_*`) win over JSON, which
  wins over application config, which wins over struct defaults
- `Planck.Headless.Config.PathList` — Skogsra type for colon-separated dir lists
- `Planck.Headless` top-level module with `config/0` entry point
- Empty supervision tree; ResourceStore, team registry, and session lifecycle
  land in later phases
