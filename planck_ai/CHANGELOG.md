# Changelog

## v0.1.0 (2026-04-17)

First release.

- Provider-agnostic streaming and completion API over `req_llm`
- Lazy event-tuple stream (`{:text_delta, _}`, `{:thinking_delta, _}`, `{:tool_call_complete, _}`, `{:done, _}`, `{:error, _}`)
- Tool calling with streaming argument assembly
- Model catalog for Anthropic, OpenAI, and Google via LLMDB
- Local server support for Ollama and llama.cpp with runtime model discovery
- JSON config loader (`Planck.AI.Config`)
- Multimodal input: text, image, image_url, file, video_url
- `Planck.AI.Config.parse_provider/1` — `String.to_existing_atom` →
  `String.to_atom`; `@valid_providers` derived from `Planck.AI.list_providers()`
  at compile time (single source of truth). Private function specs added.
