# Changelog

## v0.1.13

### Provider identifiers are sanitized instead of rejected

A provider's `identifier` (the tag used to derive its `.env` API key, e.g.
`"NVIDIA"` → `NVIDIA_API_KEY`) no longer fails the whole model load when it
contains spaces, punctuation, or lowercase letters. `Planck.AI.Config` now
normalizes it instead: upcased, disallowed characters replaced with `_`, and
leading non-letters stripped — e.g. `"Qwen 3.6 27B"` becomes `"QWEN_3_6_27B"`.
An identifier with no letters at all (e.g. `"3.6"`) still fails to load.

### Unknown model params are forwarded via `extra_body` instead of dropped

Previously, any key in a model's `params` map that wasn't a recognized
`req_llm` option (`temperature`, `max_tokens`, `top_p`, `top_k`, `min_p`,
`receive_timeout`, `anthropic_prompt_cache`, `anthropic_prompt_cache_ttl`) was
silently dropped with a log warning — losing backend-specific sampler knobs
like llama.cpp's `repetition_penalty` or `presence_penalty`. These are now
automatically merged into `extra_body` and forwarded verbatim in the request
body, same as if you'd nested them there yourself. Nothing you put in `params`
is silently lost anymore.

## v0.1.12

### `extra_body` support in model params

Models can now include an `extra_body` key in their `params` config. Its value
is a map that gets merged verbatim into the HTTP request body just before it is
sent, enabling provider-specific fields that Planck and req_llm don't expose
natively.

Primary use cases:
- **NVIDIA NIM / llama.cpp / vLLM** — `chat_template_kwargs` to control
  per-request template behaviour (e.g. `{"thinking": false}` to disable
  chain-of-thought on DeepSeek/Qwen3 models)
- Any OpenAI-compatible endpoint with vendor extensions

```json
{ "id": "deepseek", "model": "deepseek-ai/deepseek-v4-pro", "provider": "nvidia",
  "params": { "extra_body": { "chat_template_kwargs": { "thinking": false } } } }
```

### NVIDIA NIM default model updated

Default model for new NVIDIA NIM providers changed from
`qwen/qwen3-coder-480b-a35b-instruct` to `deepseek-ai/deepseek-v4-pro`.
Default `temperature` updated to `1.0` and `top_p` to `0.95` to match
NVIDIA's recommended settings for this model.

## v0.1.11

- Version bump to stay in sync with the monorepo release; no functional changes.

## v0.1.10

### Credential-proxy support

LLM requests can now be routed through an HTTPS MITM proxy (e.g. agent-vault).
Two new config keys in `Planck.AI.Config`:

- `tool_proxy` — HTTP proxy URL (e.g. `http://vault:14322`)
- `tool_proxy_ca_cert` — path to the proxy's CA certificate PEM file

When set, the Finch pool used for LLM calls is configured with
`connect_options: [proxy: url]` and `ssl: [cacertfile: path]`, allowing the
proxy to intercept requests and inject credentials transparently.

## v0.1.9

- Version bump to stay in sync with the monorepo release; no functional changes.

## v0.1.8

- Version bump; pin Burrito OTP build version to 28.5.0 to fix macOS binary builds.

## v0.1.7

- Version bump to stay in sync with the monorepo release; no functional changes.

## v0.1.6

- Drop `:custom_openai`, `:ollama`, and `:llama_cpp` providers — public provider
  atoms are now `:anthropic | :openai | :google` only
- `:openai` with `base_url` set routes to the OpenAI-compatible adapter (previously
  required `:custom_openai`); without `base_url` routes to the standard OpenAI path
- `identifier` defaults to `"OPENAI"` on `:openai` models when nil — resolves
  `OPENAI_API_KEY` for local endpoints that don't need a key
- `Planck.AI.Models.OpenAI.all/1` now accepts a `base_url:` opt to query a custom
  server's `/models` endpoint; without it returns the LLMDB catalog as before
- `Planck.AI.Models.CustomOpenAI`, `Planck.AI.Models.Ollama`, and
  `Planck.AI.Models.LlamaCpp` removed — superseded by `:openai` + `base_url`
- `Planck.AI.Model` gains `model` field — the actual provider model identifier
  (e.g. `"claude-sonnet-4-6"`); `id` becomes the user-facing alias. The adapter
  uses `model || id` so structs without the new field keep working
- `Planck.AI.Model` gains `has_api_key: boolean()` (default `true`); when `false`,
  the adapter passes `"not-needed"` directly and skips env-var lookup — for local
  servers like Ollama that require no authentication
- `Planck.AI.Config` functions `from_map/1`, `from_list/1`, and `load/1` removed — superseded
  by `from_config/2`
- `Planck.AI.Config.from_config/2` added — builds `[Model.t()]` from a providers
  map (user-keyed, each entry has a `"type"` field) and a models list (each entry
  references a provider key); this is the v0.1.6 config format

## v0.1.5

- New `:custom_openai` provider for OpenAI-compatible endpoints (NVIDIA, Together, vLLM, etc.)
- `Planck.AI.Model` gains an `identifier` field — a short uppercase tag (e.g. `"NVIDIA"`) used to derive the env var `<IDENTIFIER>_API_KEY` at request time
- `Planck.AI.Models.CustomOpenAI` — factory (`model/2`) and runtime discovery (`all/1`) via `GET {base_url}/models`
- `Planck.AI.Config` `from_map/1` validates and upcases `identifier`; rejects values that don't match `[A-Z][A-Z0-9]*`
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
