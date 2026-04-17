# Releases & Distribution

## Per-package strategy

| Package | Distribution | Notes |
|---|---|---|
| `planck_ai` | Hex.pm | Standalone LLM library, no agent dep |
| `planck_agent` | Hex.pm | Depends on `planck_ai` |
| `planck_tui` | Hex.pm | Standalone; brings in ex_ratatui NIF |
| `planck_web` | Hex.pm | Depends on Phoenix + LiveView |
| `planck_cli` | Burrito binary + GitHub Releases | Depends on all of the above |

## planck_cli — Burrito binary

Self-contained binary. Bundles the Erlang runtime. End users need no Elixir or Erlang.

Follows the same per-target release pattern as edid-generator:

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

Individual per-target releases (e.g. `planck_macos_arm`) are also defined for CI
cross-compilation jobs that build one target at a time.

## planck_cli — execution modes

The binary detects its mode at startup — no separate binaries per mode.

```sh
planck                        # TUI mode (TTY detected)
planck "fix the auth bug"     # print mode (argument provided, no TUI)
planck --print "explain this" # explicit print mode
```

TTY detection at startup:
```elixir
if :io.columns() == {:error, :enotsup} do
  Planck.PrintMode.start()
else
  Planck.TUIMode.start()
end
```

## planck_web — execution modes

`planck_web` is a Hex library for embedding LiveView chat components in any Phoenix app.
It is not a Burrito binary.

```sh
# Development
iex -S mix phx.server

# Production (standard OTP release, not Burrito)
mix release planck_web
_build/prod/rel/planck_web/bin/planck_web start
```

The `planck_web/` folder contains a demo Phoenix app showing library usage. The library
itself is the distributable artifact.

## Hex library releases

Each library is versioned and published independently:

```sh
cd planck_ai && mix hex.publish
```

Users depend only on what they need:

```elixir
{:planck_ai, "~> 0.1"}       # LLM abstraction only
{:planck_agent, "~> 0.1"}    # agent runtime (pulls planck_ai transitively)
{:planck_tui, "~> 0.1"}      # TUI widgets
{:planck_web, "~> 0.1"}      # Phoenix LiveView components
```

## Version policy

All packages share the same version number and are released simultaneously. Version is
defined once per `mix.exs` via a module attribute and kept in sync manually (or via a
root-level Mix task).
