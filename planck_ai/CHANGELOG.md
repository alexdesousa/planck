# Changelog

## v0.1.5

- New `:custom_openai` provider for OpenAI-compatible endpoints (NVIDIA, Together, vLLM, etc.)
- `Planck.AI.Model` gains an `identifier` field — a short uppercase tag (e.g. `"NVIDIA"`) used to derive the env var `<IDENTIFIER>_API_KEY` at request time
- `Planck.AI.Models.CustomOpenAI` — factory (`model/2`) and runtime discovery (`all/1`) via `GET {base_url}/models`
- `Planck.AI.Config.from_map/1` validates and upcases `identifier`; rejects values that don't match `[A-Z][A-Z0-9]*`
- API keys for `:custom_openai` are resolved lazily from the environment at request time, never cached

## v0.1.4

- Version bump to stay in sync with the monorepo release; no functional changes.

## v0.1.3

- Version bump to stay in sync with the monorepo release; no functional changes.

## v0.1.2

- Version bump to stay in sync with the monorepo release; no functional changes.

## v0.1.1

- `ex_doc` bumped to `~> 0.40.2`; no functional changes.

## v0.1.0

First release.

- Provider-agnostic streaming and completion API over `req_llm`
- Lazy event-tuple stream (`{:text_delta, _}`, `{:thinking_delta, _}`, `{:tool_call_complete, _}`, `{:done, _}`, `{:error, _}`)
- Tool calling with streaming argument assembly
- Model catalog for Anthropic, OpenAI, and Google via LLMDB
- Local server support for Ollama and llama.cpp with runtime model discovery
- JSON config loader (`Planck.AI.Config`)
- Multimodal input: text, image, image_url, file, video_url
- `parse_provider/1` (private) — `String.to_existing_atom` →
  `String.to_atom`; `@valid_providers` derived from `Planck.AI.list_providers()`
  at compile time (single source of truth). Private function specs added.
