# Changelog

## v0.1.7

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
- `sidecar/mix.exs` — `local_or_hex/2` helper so `PLANCK_LOCAL=true` uses local
  `planck_agent` deps instead of Hex.

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
