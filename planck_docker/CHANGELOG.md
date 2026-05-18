# Changelog

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
  Apache Tika for text extraction. Results cached to `doc_cache/` with mtime
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

- Built on `hexpm/elixir:1.19.5-erlang-28.5-ubuntu-24.04`; uses the
  `planck_docker` OTP release target (standard Mix release, no Burrito).
- Entrypoint copies the bundled sidecar and renders `default_config.json.template`
  via `envsubst` on first run. Template variables (`LLAMA_CTX_SIZE`, `LLAMA_PORT`)
  keep the config in sync with the llama-cpp container's env vars automatically.
- Binds to `0.0.0.0:4000` inside the container; host binding controlled by
  `PLANCK_BIND_ADDRESS` (default `127.0.0.1` — local only, no open ports).
