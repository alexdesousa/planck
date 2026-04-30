# Planck

> **Planck length** (*noun*, `/ˈplæŋk leŋθ/`) — the smallest meaningful unit of
> distance in physics, approximately 1.616 × 10⁻³⁵ metres; the scale at which
> quantum gravitational effects become significant and below which the concept of
> space itself breaks down.

Planck is a coding agent CLI and a suite of reusable Elixir libraries for building
AI-powered applications. It is a full Elixir reimagining of the
[pi-mono](https://github.com/badlogic/pi-mono) coding agent ecosystem.

Agents are BEAM processes. Subagents are spawned processes. Inter-agent communication
is message passing. The TUI and Web UI are published to Hex as libraries any Elixir
developer can use independently. The coding agent ships as a self-contained binary
called `planck`.

---

## Packages

| Package | Description | Distribution |
|---|---|---|
| [`planck_ai`](./planck_ai) | LLM provider abstraction over `req_llm` | Hex |
| [`planck_agent`](./planck_agent) | OTP-based agent runtime | Hex |
| [`planck_headless`](./planck_headless) | Headless core — config, resources, session lifecycle | Hex |
| [`planck_cli`](./planck_cli) | Coding agent CLI — TUI + Web UI + Burrito binary | Burrito binary |

`planck_ai`, `planck_agent`, and `planck_headless` are standalone Hex libraries.
The TUI and Web UI live inside `planck_cli` rather than as separate packages — they
are rendering surfaces, not reusable components.

A [`playground/`](./playground) directory provides a ready-to-run sandbox
against a local llamacpp or Ollama server — useful for testing sessions end-to-end.

## Design principles

**Agents are processes.** Each agent instance is a `GenServer`. Subagents are spawned
processes supervised under a `DynamicSupervisor`. No special subagent abstraction
needed — it is just the BEAM.

**OTP all the way down.** Supervision trees, fault tolerance, and process linking are
not add-ons — they are the architecture. An agent crash does not take down the TUI.

**Libraries on Hex, binary on GitHub.** `planck_ai`, `planck_agent`, and
`planck_headless` are usable by any Elixir developer building AI-powered applications.
The coding agent ships as a self-contained Burrito binary — non-Elixir users install
and run it without knowing Mix or Erlang.

**Extensions without compilation.** The primary extension path is a plain `.ex` source
file loaded via `Code.compile_file/2` at startup — no build step required.

## Status

Active development. `planck_ai`, `planck_agent`, and `planck_headless` are built and
tested. `planck_cli` (TUI + Web UI + Burrito binary) is next. See [`specs/`](./specs)
for design decisions.

## Development

This is a monorepo. Each package is developed and tested independently.

```sh
cd planck_ai
PLANCK_LOCAL=true mix deps.get
mix test
```

Set `PLANCK_LOCAL=true` to resolve sibling packages from disk instead of Hex.

See [`specs/project-structure.md`](./specs/project-structure.md) for the full monorepo
setup and [`specs/quality-and-tooling.md`](./specs/quality-and-tooling.md) for code
quality standards enforced across all packages.
