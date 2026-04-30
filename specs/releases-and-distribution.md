# Releases & Distribution

## Per-package strategy

| Package | Distribution | Notes |
|---|---|---|
| `planck_ai` | Hex.pm | Standalone LLM library, no agent dep |
| `planck_agent` | Hex.pm | Depends on `planck_ai` |
| `planck_headless` | Hex.pm | Depends on `planck_agent` |
| `planck_cli` | Burrito binary + GitHub Releases | Depends on all of the above; contains TUI + Web UI |

The TUI and Web UI are not separate Hex packages. They live inside `planck_cli` as
internal modules. Anyone wanting to build their own UI depends on `planck_headless`
directly and writes their own rendering surface.

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

The binary detects its mode at startup — no separate binaries per mode.

```sh
planck                        # TUI mode (TTY detected)
planck "fix the auth bug"     # print mode (argument provided, no TUI)
planck --web                  # Web UI mode (starts Phoenix server)
```

TTY detection at startup:

```elixir
cond do
  "--web" in argv               -> Planck.WebMode.start(argv)
  :io.columns() == {:error, :enotsup} -> Planck.PrintMode.start(argv)
  true                          -> Planck.TUIMode.start(argv)
end
```

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
