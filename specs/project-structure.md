# Project Structure

## Monorepo, no umbrella

Each package is a fully independent Mix project in its own subdirectory. They are not
linked via an Elixir umbrella (`apps_path`). Each has its own `mix.exs`, `mix.lock`,
and `priv/plts/` for Dialyzer PLT caching.

```
planck/
├── .github/
│   └── workflows/
│       ├── planck_ai.yml
│       ├── planck_agent.yml
│       ├── planck_headless.yml
│       ├── planck_tui.yml
│       ├── planck_web.yml
│       └── planck_cli.yml
├── planck_ai/        — LLM provider abstraction       → Hex library
├── planck_agent/     — OTP agent runtime              → Hex library
├── planck_headless/  — Headless core: startup, sessions, resource loading → Hex library
├── planck_tui/       — Terminal UI primitives         → Hex library
├── planck_web/       — Phoenix LiveView components    → Hex library
├── planck_cli/       — Coding agent CLI (TUI + Web)   → Burrito binary
└── specs/            — Design decisions (this folder)
```

## Inter-package dependencies

During development, packages reference siblings via path deps controlled by an env var.
In CI and after Hex release, they use version refs.

```elixir
# In each mix.exs:
defp local_or_hex(package, version) do
  if System.get_env("PLANCK_LOCAL") == "true" do
    {package, path: "../#{package}"}
  else
    {package, version}
  end
end
```

Usage: `PLANCK_LOCAL=true mix test` inside any package resolves siblings from disk.

## Dependency graph

```
planck_ai
    ↑
planck_agent
    ↑
planck_headless
    ↑         ↑
planck_tui  planck_web
    ↑         ↑
       planck_cli
```

`planck_ai` has no internal deps — safe to build and test in isolation first.

`planck_headless` is the layer that owns startup orchestration, resource loading
(tools, skills, compactor), session lifecycle, and model availability. TUI and WebUI
are rendering surfaces that depend on it — they never talk to `planck_agent` directly.

`planck_cli` bundles both `planck_tui` and `planck_web` into a single Burrito binary.
Running `planck tui` starts headless with the ratatui interface; `planck web` starts
headless with the Phoenix interface. Both share the same session store and tool config.

## Package roles

| Package | Role | Distribution |
|---|---|---|
| `planck_ai` | LLM provider abstraction | Hex library |
| `planck_agent` | OTP agent runtime | Hex library |
| `planck_headless` | Startup, sessions, resource wiring | Hex library |
| `planck_tui` | Terminal UI primitives | Hex library |
| `planck_web` | Phoenix LiveView components | Hex library |
| `planck_cli` | Coding agent CLI — bundles TUI + Web | Burrito binary |

`planck_ai`, `planck_agent`, `planck_headless`, `planck_tui`, and `planck_web` are
all usable independently as Hex libraries. Anyone can build their own UI on top of
`planck_headless` without depending on either bundled interface.

## CI per package

Each workflow file:
- Triggers only on changes inside its package directory (`paths: ["planck_ai/**"]`)
- Sets `defaults.run.working-directory` to the package folder
- Mirrors the Skogsra `checks.yml` structure exactly (two jobs: `test` + `dialyzer`)
- Uses OTP 28 / Elixir 1.19 (kept in sync across all packages)
