# Planck

> **Planck length** (*noun*, `/ˈplæŋk leŋθ/`) — the smallest meaningful unit of
> distance in physics, approximately 1.616 × 10⁻³⁵ metres; the scale at which
> quantum gravitational effects become significant and below which the concept of
> space itself breaks down.

Planck is a coding agent CLI and a suite of reusable Elixir libraries for building
AI-powered applications. It is a full Elixir reimagining of the
[pi-mono](https://github.com/badlogic/pi-mono) coding agent ecosystem.

Agents are BEAM processes. Subagents are spawned processes. Inter-agent communication
is message passing. `planck_ai`, `planck_agent`, and `planck_headless` are published
to Hex as reusable libraries. The coding agent ships as a self-contained binary
called `planck`.

https://github.com/user-attachments/assets/4045b308-4b1c-4315-9024-11574a8c8eb5

---

## Packages

| Package | Description | Distribution |
|---|---|---|
| [`planck_ai`](./planck_ai) | LLM provider abstraction over `req_llm` | Hex |
| [`planck_agent`](./planck_agent) | OTP-based agent runtime | Hex |
| [`planck_headless`](./planck_headless) | Headless core — config, resources, session lifecycle | Hex |
| [`planck_cli`](./planck_cli) | Coding agent CLI — Web UI + HTTP API + Burrito binary | Burrito binary |

`planck_ai`, `planck_agent`, and `planck_headless` are standalone Hex libraries.
The Web UI and HTTP API live inside `planck_cli` — rendering surface and external
integration layer on top of `planck_headless`.

## Design principles

**Agents are processes.** Each agent instance is a `GenServer`. Subagents are spawned
processes supervised under a `DynamicSupervisor`. No special subagent abstraction
needed — it is just the BEAM.

**OTP all the way down.** Supervision trees, fault tolerance, and process linking are
not add-ons — they are the architecture. An agent crash does not take down the UI.

**Libraries on Hex, binary on GitHub.** `planck_ai`, `planck_agent`, and
`planck_headless` are usable by any Elixir developer building AI-powered applications.
The coding agent ships as a self-contained Burrito binary — non-Elixir users install
and run it without knowing Mix or Erlang.

**Extensions without compilation.** The primary extension path is a plain `.ex` source
file loaded via `Code.compile_file/2` at startup — no build step required.

## Status

Active development. All four packages are built and tested. The Web UI in
`planck_cli` is functional — sessions, streaming, multi-agent teams, skills,
sidecar integration, i18n (English + Spanish), HTTP API with OpenAPI/Swagger UI.
Burrito binary distribution is next.

See [`specs/`](./specs) for design decisions.

## Running

### On your computer

For end users — install the released binary, no Elixir/Mix required:

```bash
# Linux / macOS
curl -fsSL https://thebroken.link/planck/install.sh | sh
planck
# → http://localhost:4000
```

```powershell
# Windows
irm https://thebroken.link/planck/install.ps1 | iex
planck
```

That's the bare CLI. There's also an opinionated, Docker-based stack that
bundles private web search (Searxng), workspace indexing (Typesense), document
extraction (Apache Tika), a credential proxy (agent-vault), long/short-term
memory, and shared task tracking (Beads) around it — one command, requires
Docker:

```bash
# Linux / macOS
curl -fsSL https://thebroken.link/planck/install_docker.sh | sh
```

```powershell
# Windows
irm https://thebroken.link/planck/install_docker.ps1 | iex
```

See [`docs/index.html`](./docs/index.html) for what each service in that stack
does and why it exists.

### For development

Building and running from source, for working on Planck itself.

Bare CLI, no sidecar/search/indexing:

```bash
elixir --sname planck_cli -S mix run --no-halt
# → http://localhost:4000
```

The `--sname` flag enables Erlang distribution so the optional sidecar can
connect back. See [`planck_cli/README.md`](./planck_cli/README.md) for details.

The full stack, built from source instead of pulling the released images — use
this to pick up local changes to `planck_docker/`:

```bash
./dev_docker.sh              # fresh environment: tears down and rebuilds
./dev_docker.sh preserve     # keep existing data, just rebuild images and restart
./dev_docker.sh init-config  # fresh environment + write a deep-thought team config
```

Data lives in `.planck-dev/` (gitignored) so it doesn't touch `~/planck`. See
[`skills/planck_setup/`](./skills/planck_setup) for configuring the resulting
environment.

## Testing

This is a monorepo. Each package is developed and tested independently.

```sh
cd planck_ai
mix deps.get
mix test
```


A `./check` script at the monorepo root runs format, compile, credo, tests, and
dialyzer across all packages:

```sh
./check               # all packages
./check planck_agent  # specific package
```

See [`specs/project-structure.md`](./specs/project-structure.md) for the full monorepo
setup and [`specs/quality-and-tooling.md`](./specs/quality-and-tooling.md) for code
quality standards enforced across all packages.
