# Changelog

## v0.2.3

### `read` tool double-joined the workspace path

`Sidecar.Tools.Read` (the Tika-extraction-aware `read` shadowing the
built-in) failed with `enoent` on an absolute path like
`/workspace/.planck/skills/planck_setup/references/teams.md`, even though
the file existed — `check_allowed_path/1` already returns a fully-expanded
absolute path (needed to validate against both `/workspace/` and `/tmp/`),
but `do_read/2` joined `workspace` onto it a second time. Elixir's
`Path.join/2` doesn't special-case an absolute right-hand side, so the
result was `/workspace/workspace/...` — a path that never exists. Fixed by
passing the already-resolved absolute path straight through to `do_read/3`
instead of re-deriving it; the original (possibly relative) path is kept
alongside it only for display purposes. Two regression tests added: reading
via an absolute path under the workspace, and via an absolute path under
`/tmp`.

## v0.2.2

### Fresh installs via `curl | sh` were completely broken

Two separate bugs, both hit for real installing `v0.2.1`:

- `docker compose run --rm setup` requested a pseudo-TTY by default. When the
  install script itself runs via `curl | sh` (or `irm | iex` on Windows),
  stdin is the pipe feeding the script, not a real terminal, so TTY allocation
  failed outright ("the input device is not a TTY") and `set -e` aborted the
  whole install before any service ever started. `setup`'s entrypoint is a
  plain, non-interactive script — it never needed a TTY. Fixed by adding `-T`
  to that one `run` call, in `install_docker.sh`, `install_docker.ps1`, and
  `dev_docker.sh`.
- `dolt` and `beads` are built locally rather than published as per-version
  images (see `specs/planck-docker.md`), and their `compose.yml` build
  contexts were `context: .. / dockerfile: planck_docker/dolt/Dockerfile` —
  paths that only resolve when `compose.yml` sits inside a full monorepo
  checkout. A standalone install has no `planck_docker/` directory above
  `compose.yml` at all, so `docker compose up` failed immediately trying to
  build `dolt` from a path that doesn't exist. Fixed structurally: both
  Dockerfiles now `COPY` from their own directory instead of a
  monorepo-root-relative path, `compose.yml`'s build contexts are now
  `context: ./dolt` / `context: ./beads` (resolved relative to `compose.yml`'s
  own directory either way, so `dev_docker.sh` is unaffected), and
  `install_docker.sh`/`install_docker.ps1` now download `planck_docker/dolt`
  and `planck_docker/beads` from the tagged release archive alongside
  `compose.yml`, landing them right next to it.

## v0.2.1

### Release CI fixes

`v0.2.0`'s tag had to be re-cut twice while chasing release pipeline failures,
and Hex.pm rejected re-publishing the same version once more than an hour had
passed since its first publish — hence this version bump, with no functional
changes to the shipped image. The underlying pipeline fixes, kept from that
work:

- `build-linux`/`build-macos-arm` in `release.yml` pinned to the exact OTP
  patch (`29.0.6`) confirmed mirrored on Burrito's ERTS CDN, instead of a
  two-component pin that can silently drift to a newer, unmirrored patch
  between runs.
- `planck_docker.yml`'s Docker image build now builds `linux/amd64` and
  `linux/arm64` on their own native runners and merges the digests into one
  multi-arch manifest, instead of a single QEMU-emulated multi-platform build.
- `erlexec`'s C build (a transitive dep of both `planck_cli` and the sidecar)
  shells out to bare `erl` to detect the system architecture and
  `erl_interface` paths; that `erl` invocation crashes on boot on the
  `hexpm/elixir:*-erlang-29.1-*` image regardless of architecture or QEMU
  (`prim_tty`'s NIF-based terminal handling fails with `undef`). Fixed in
  `planck_docker/planck/Dockerfile` by setting `CROSS_COMPILE=1` and
  pre-computing `ERL_CXXFLAGS`/`ERL_LDFLAGS` from the filesystem, so `erl` is
  never invoked for this.

## v0.2.0

### Shared task tracking — beads

New `dolt` and `beads` compose services provide a shared task board for the
whole team. `Sidecar.Beads` (HTTP client) and seven LLM-facing tools —
`bd_ready`, `bd_get`, `bd_done`, `bd_claim`, `bd_create`, `bd_delete`,
`bd_list` — let agents claim, create, and close work items; every mutating
call attaches a "view board" UI button so a human can always open the live
kanban widget. Issue ids use a `planck-N` prefix.

Several real bugs found and fixed against the actual published images, not
assumed: dolt's healthcheck uses a raw TCP connect (`sql-client` isn't a real
subcommand, and the published image ships no MySQL client); dolt's
auto-created `root` user is scoped to `localhost` only by default (a custom
entrypoint self-grants `root@'%'` on boot); `bd init --server`'s `--prefix`
derivation needed an explicit value; `Sidecar.Beads.close/3` always sent a
literal `reason: nil`, which the API rejects outright (fixed to omit the key,
matching how `create/3` already handled optional fields).

### `phoenix_live_view` in the sidecar

Added so sidecar widget modules can build their UI with `Phoenix.Component`/`~H`
and flatten it to a plain HTML string before crossing the RPC boundary — no
`Endpoint`/`Router`/Cowboy needed, the sidecar still runs standalone.

### Sidecar localization

`Sidecar.Gettext` — sidecar-rendered widgets (the beads board) now have their
own translation catalog (`en`/`es`), since the sidecar runs as a genuinely
separate distributed-Erlang node and can't share a Gettext process with
`planck_cli`.

## v0.1.13

- Version bump to stay in sync with the monorepo release; no functional changes.

## v0.1.12

- Version bump to stay in sync with the monorepo release; no functional changes.

## v0.1.11

- Version bump to stay in sync with the monorepo release; no functional changes.

## v0.1.10

### Agent-vault credential proxy

The Docker stack now includes [Infisical agent-vault](https://github.com/infisical/agent-vault)
as an internal HTTPS MITM proxy. All outbound LLM and tool HTTP calls from the
sidecar route through the proxy, which injects credentials transparently. Agents
never see API keys — the proxy handles authentication unconditionally based on
host-matching service rules.

Port 14321 (vault management API) is intentionally not published. All credential
and service-rule management happens through Planck's own secrets modal.

### Vault bootstrap — scoped agent token

The `setup` container now bootstraps agent-vault on first run:
1. Registers the owner account
2. Creates the `planck` vault
3. Creates a scoped `planck-sidecar` agent with `admin` role on the `planck` vault
4. Writes `AGENT_VAULT_TOKEN` to `$PLANCK_HOME/.env`

The token is picked up by Docker Compose on `up` and injected into the planck
container environment. The sidecar inherits it via erlexec's additive env. Admin
credentials (`AGENT_VAULT_EMAIL`, `AGENT_VAULT_PASSWORD`) never leave the setup
container.

### Vault data as bind-mount

`vault-data` is now a bind-mount directory (`$PLANCK_HOME/vault-data`) rather
than a named Docker volume. This matches the pattern used by `typesense-data` and
makes it easy to inspect or delete vault state from the host.

### `Sidecar.Secrets.AgentVault`

New `Planck.Agent.Secrets` implementation backed by the agent-vault management
API. Manages credentials and service rules; auto-migrates keys from `.env` on
first sidecar startup.

## v0.1.9

- Version bump to stay in sync with the monorepo release; no functional changes.

## v0.1.8

- Version bump; pin Burrito OTP build version to 28.5.0 to fix macOS binary builds.

## v0.1.7

### Skill Reflector

After every LLM turn that contained five or more tool calls, the bundled sidecar
now automatically reflects on the conversation and decides whether to capture the
workflow as a reusable agent skill.

- **`Sidecar.Tools.WriteSkill`** — writes or updates
  `{workspace}/.planck/skills/<name>/SKILL.md`. Frontmatter is generated with
  `Ymlr` and parsed with `:yamerl_constr`; `creator: agent` is always set by the
  tool; `always_present` is preserved from an existing file on update (a
  user-set `true` survives rewrites). Returns `"create_skill:name"` or
  `"update_skill:name"` for injection signalling. `ymlr ~> 5.1` added as dep.

- **`Sidecar.Tools.ListSkills`** — a filtered `list_skills` tool that shows only
  skills with `creator: "agent"`. Used exclusively inside the reflector's
  mini-agent so it does not surface user-curated skills.

- **`Sidecar.SkillReflector.Prompt`** — builds the system prompt for the
  mini-agent: instructs it to call `list_skills` first, evaluate repeatability,
  and write structured skills (When to Use, Quick Reference, Procedure, Pitfalls,
  Verification sections).

- **`Sidecar.SkillReflector.Runner`** — transient GenServer that manages one
  reflection cycle. Starts an ephemeral `Planck.Agent` under
  `Planck.Agent.AgentSupervisor` with the `list_skills`, `load_skill`, and
  `write_skill` tools. Links to the mini-agent and subscribes to its PubSub.
  `@max_tool_calls 15` stops the cycle if the tool call count exceeds the limit,
  preventing runaway loops. On `:tool_end` for `write_skill`: stores the result
  string. On `:turn_end`: injects a `create_skill` or `update_skill` synthetic
  tool result into the parent agent via `Planck.Agent.inject_tool_result/3`, then
  stops (the mini-agent dies with it via the link).

- **`Sidecar.SkillReflector`** — implements `Planck.Agent.Hooks.TurnEnd`.
  `reflect_threshold/0` returns 5. `reflect/2` calls `Runner.start/2` directly
  (already in a background task from agent.ex). Enable per-agent in TEAM.json:
  `"turn_end_hook": "Sidecar.SkillReflector"`.

- Integration tests cover the full flow using `MockAI` (defined in
  `sidecar/test_helper`): `list_skills → write_skill → create_skill` injection;
  skip scenario; and the public `reflect/2` interface.

- **`dev_docker.sh`** — model download removed; `planck_setup` skill copied from
  local `skills/planck_setup/`; `PLANCK_HOME` added to `.env`; `add_if_missing`
  pattern adopted.

### Skill Reflector — objective 2: filtered `list_skills` tool

- `Sidecar.Tools.ListSkills` — a `list_skills` tool restricted to agent-created
  skills (`creator: agent`). Used exclusively inside the SkillReflector's
  mini-agent so it only sees skills it wrote itself — user-curated skills are
  not surfaced to avoid unintended rewrites.

### Skill Reflector — objective 1: `write_skill` tool

- `Sidecar.Tools.WriteSkill` — new sidecar tool that writes or updates a skill
  file at `{workspace}/.planck/skills/<name>/SKILL.md`:
  - `creator: agent` and `planck_version: null` always set by the tool
  - `always_present` preserved from existing file on update (user-set `true`
    survives rewrites), parsed via `:yamerl_constr`
  - Action detection: `"create_skill"` if file did not exist, `"update_skill"`
    if it did — returned in the result for synthetic tool injection
  - Frontmatter generated using `Ymlr.Encode.to_s!/1` for correct YAML quoting
    of all scalar values
- `ymlr ~> 5.1` added as dependency for YAML generation

### Session indexing and search

- `Sidecar.SessionIndexer` — new GenServer that subscribes to the
  `"planck:sessions"` global PubSub topic and indexes each turn into a
  Typesense `long_term_memory` collection (configurable via
  `TYPESENSE_SESSIONS_COLLECTION`, default `"long_term_memory"`). One document
  per turn combines the user/trigger message and the agent response, labelled
  by agent name.
- `session_search` sidecar tool — queries the `long_term_memory` Typesense
  collection for relevant past turns; accepts an optional `agent_name` filter.
- `Sidecar.Config` — new `sessions_collection` key (`TYPESENSE_SESSIONS_COLLECTION`,
  default `"long_term_memory"`).

### Per-agent memory (Phase 3)

- `Sidecar.Typesense` — new unified Typesense HTTP client module used by all
  five sidecar modules (`Watcher`, `SessionIndexer`, `Memory`, `SearchWorkspace`,
  `SessionSearch`). Provides: `ready?/0`, `ensure_collection/1`, `upsert/2`,
  `get/2`, `delete/2`, `search/2`, `url/1`, `headers/0`. Replaces per-module
  private HTTP helpers.
- `Sidecar.Memory` — new GenServer implementing `Planck.Agent.Hooks.Prompt`:
  - ETS table `:sidecar_memory` keyed by `session_id` for fast non-blocking reads
  - `before_prompt/1` reads from ETS and injects memory before the base system prompt
  - On `:turn_end` event (lazy load): if ETS miss, fetches from
    `short_term_memory` Typesense collection by `"#{team_name}:#{agent_name}"`
  - On `:compacted` event: refreshes ETS from Typesense with the latest persisted memory
  - `write/3` — upserts to `short_term_memory` Typesense and updates ETS
  - `current/1` — reads current memory from Typesense by agent key
  - `flush/0` — test synchronization helper
  - Enabled per-agent via TEAM.json: `"prompt_hook": "Sidecar.Memory"`
- `Sidecar.Tools.UpdateMemory` — new `update_memory` sidecar tool with two actions:
  - `"append"` (default): loads existing memory, concatenates new fact, checks
    `memory_size` (chars per line summed) against the 2 200-char limit; if over
    limit, returns full combined content with instruction to summarize and call
    with `"overwrite"`
  - `"overwrite"`: replaces memory entirely, no size check — used after the
    agent summarizes
  - Added to `Sidecar.Planck.tools/0`
- `Sidecar.Config` — new `memory_collection` key (`TYPESENSE_MEMORY_COLLECTION`,
  default `"short_term_memory"`); `sessions_collection` default renamed from
  `"memory"` to `"long_term_memory"`.
- `sidecar/mix.exs` — `local_or_hex/2` auto-detects local `planck_agent` by
  checking if the path exists, with Hex fallback for standalone installs.

### Collection naming convention

| Collection | Purpose |
|---|---|
| `long_term_memory` | Indexed turn history (append-only, queried by `session_search`) |
| `short_term_memory` | Condensed agent memory keyed by `"team_name:agent_name"` (one record per agent, replace-on-write, injected via `before_prompt`) |

### planck_setup bundled skill

- `skills/planck_setup/` installed at first run by the install scripts; guides
  for configuring providers, teams, skills, sidecars, hooks, and the HTTP API.

## v0.1.6

- `llama-cpp` service removed — local LLM is no longer bundled. Configure any
  provider (NVIDIA NIM, Groq, Ollama, etc.) via the SetupModal after first run.
- `planck_docker/llama-cpu/Dockerfile` removed.
- `default_config.json.template` replaced with an empty config (`{}`);
  the SetupModal opens automatically on first launch and guides the user through
  provider and model setup.
- `LLAMA_*` env vars (`LLAMA_CTX_SIZE`, `LLAMA_PORT`, `LLAMA_THREADS`,
  `LLAMA_SLEEP_IDLE_SECONDS`) removed from `compose.yml` and install scripts.
- `install_docker.sh` and `install_docker.ps1`: model download step removed;
  `models/` directory no longer created; `compose.yml` always re-downloaded;
  `.env` handling changed to `add_if_missing` — re-running the installer adds
  any new keys without overwriting existing values; version bumped to 0.1.6.
- Image tags bumped to `0.1.6`.

## v0.1.5

- Images bumped to v0.1.5 — picks up `:custom_openai` provider support and the
  config-merge fix from `planck_headless` / `planck_cli` v0.1.5.

## v0.1.4

- Version bump to stay in sync with the monorepo release; no functional changes.

## v0.1.3

### Initial release

A Docker Compose stack that runs Planck with a local LLM, web search, workspace
indexing, and document extraction. Designed to be installed once by a technical
user for themselves or for others.

#### llama.cpp (CPU)

- Dockerfile built from `PrismML-Eng/llama.cpp` (pinned commit) — CPU-only,
  no CUDA required. Bonsai-8B-Q1_0 (1.16 GB) runs conversationally on modern
  CPUs.
- Configurable via env vars: `LLAMA_THREADS` (default 8), `LLAMA_CTX_SIZE`
  (default 32768), `LLAMA_PORT` (default 11434).

#### Bundled sidecar

A Mix project (`planck_docker/sidecar/`) pre-installed in the planck image and
copied to the workspace on first run. Four tools:

- **`read`** — shadows the built-in `read` tool. Plain text and code files are
  read directly; binary formats (PDF, DOCX, XLSX, ODS, PPTX, etc.) are sent to
  Apache Tika via `PUT /tika` (Tika 3.x requires PUT, not POST) for text
  extraction. Results cached to `doc_cache/` with mtime
  invalidation. Format header prepended so agents know the file cannot be edited
  with `edit`.
- **`search_workspace`** — full-text search over indexed workspace files via
  Typesense.
- **`search_web`** — privacy-respecting web search via a local Searxng instance.
- **`web_fetch`** — fetches a URL, extracts clean markdown via
  `@mozilla/readability` + turndown. Results cached to `web_cache/` with mtime
  invalidation and offset/limit pagination.

Binary vs text detection uses the first 4 KB of file content (`String.valid?/1`)
rather than extension lists — works for extensionless files and any future format.

`Sidecar.Config` (Skogsra) manages all service URLs and credentials:
`WORKSPACE_DIR`, `TYPESENSE_URL`, `TYPESENSE_API_KEY`, `TYPESENSE_COLLECTION`,
`SEARXNG_URL`, `TIKA_URL`.

#### Planck container

- Built on `hexpm/elixir:1.19.5-erlang-28.5-ubuntu-noble-20260410`; uses the
  `planck_docker` OTP release target (standard Mix release, no Burrito).
- `inotify-tools` installed for `file_system` live-reload support.
- Entrypoint copies the bundled sidecar and renders `default_config.json.template`
  via `envsubst` on first run. Template variables (`LLAMA_CTX_SIZE`, `LLAMA_PORT`)
  keep the config in sync with the llama-cpp container's env vars automatically.
- Binds to `0.0.0.0:4000` inside the container; host binding controlled by
  `PLANCK_BIND_ADDRESS` (default `127.0.0.1` — local only, no open ports).
- `setup` service uses `entrypoint: ["/setup.sh"]` to bypass the planck
  release entrypoint and exit cleanly, unblocking dependent services.
