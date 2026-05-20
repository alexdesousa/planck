# Changelog

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
  `models/` directory no longer created; `compose.yml` always re-downloaded
  (idempotent); version bumped to 0.1.6.
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
