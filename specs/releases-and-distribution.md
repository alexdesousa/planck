# Releases & Distribution

## Per-package strategy

| Package | Distribution | Notes |
|---|---|---|
| `planck_ai` | Hex.pm | Standalone LLM library, no agent dep |
| `planck_agent` | Hex.pm | Depends on `planck_ai` |
| `planck_headless` | Hex.pm | Depends on `planck_agent` |
| `planck_cli` | Burrito binary + GitHub Releases | Depends on all of the above; contains Web UI + HTTP API |

The Web UI and HTTP API are not separate Hex packages. They live inside `planck_cli`
as internal modules. Anyone wanting to build their own interface depends on
`planck_headless` directly.

## planck_cli — Burrito binary

Self-contained binary. Bundles the Erlang runtime. End users need no Elixir or Erlang.

```elixir
def releases do
  [
    planck: [
      steps: [:assemble, &Burrito.wrap/1],
      burrito: [
        targets: [
          macos_arm:  [os: :darwin,  cpu: :aarch64],
          macos_x86:  [os: :darwin,  cpu: :x86_64],
          linux_x86:  [os: :linux,   cpu: :x86_64],
          linux_arm:  [os: :linux,   cpu: :aarch64],
          windows:    [os: :windows, cpu: :x86_64]
        ],
        debug: Mix.env() != :prod
      ]
    ]
  ]
end
```

## planck_cli — execution modes

```sh
planck           # Start the web server (default)
planck web       # Start the web server
planck --help    # Print usage
planck --version # Print version
```

The web server starts the Phoenix app which serves both the Web UI and the HTTP
API. For CI pipelines and external integrations, use the HTTP API directly
(`GET /api/sessions`, `POST /api/sessions/:id/prompt`, etc.) — no separate
headless mode is needed.

## Hex library releases

Each library is versioned and published independently:

```sh
cd planck_ai && mix hex.publish
```

Users who want to build on top of Planck depend only on what they need:

```elixir
{:planck_ai, "~> 0.1"}          # LLM abstraction only
{:planck_agent, "~> 0.1"}       # agent runtime (pulls planck_ai transitively)
{:planck_headless, "~> 0.1"}    # full headless stack (pulls planck_agent transitively)
```

## Version policy

All packages share the same version number and are released simultaneously. Version is
defined once per `mix.exs` via a module attribute and kept in sync manually (or via a
root-level Mix task).
