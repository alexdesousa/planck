# Phase 1 — `planck_ai`: `type` field + `:typesafe` provider + `evaluate/4`

Part of [v0.2.4-spec](../v0.2.4-spec.md).

## Objective

Give `planck_ai` everything needed to represent and call an RLCD model: a
`type` field on `Planck.AI.Model` distinguishing `:llm` from `:rlcd`, a
`:typesafe` provider (cloud and self-hosted-compatible, mirroring the
existing `:openai` split), and a `Planck.AI.evaluate/4` entry point that
reaches `req_llm`'s already-complete `ReqLLM.Providers.TypeSafe` (`POST
/v1/systemone`). Nothing in `req_llm` itself changes — this phase is entirely
the typed layer on top of it.

## Plan

**Pre-work — resolved.** `https://docs.typesafe.ai/api.md` and
`/primitives/advanced.md` give the confirmed contract (`decider`'s README
was cross-checked too, since it claims wire compatibility):

1. **A model-listing endpoint exists**: `GET /v1/models` (cloud), returning
   `{"models": [{"name", "description", "release_date"}, ...]}`. Note the
   path includes the version prefix itself — unlike `:openai`'s
   `#{base_url}/models` convention (where `base_url` already ends in
   `/v1`), Typesafe's `default_base_url` is bare (`https://api.typesafe.ai`,
   per `ReqLLM.Providers.TypeSafe`), so the query path is
   `"#{base_url}/v1/models"`. **Self-hosted/compatible servers may not
   implement it** — `decider`'s README documents no such endpoint — so
   `Models.TypeSafe.all/1` (below) must degrade gracefully on a non-200,
   the same pattern `Models.OpenAI.query_endpoint/2` already uses, not
   assume every `base_url` supports discovery.
2. **Confirmed per-question field names** — all three types use `criteria`,
   not `criteria`-for-choice/`levels`-for-score as an earlier draft of this
   spec guessed:
   - `choice`: `criteria` **required**, object mapping option key →
     description (up to 255 options).
   - `score`: `criteria` **required**, array of 2-10 level descriptions
     (order matters — response `legend` indexes into it positionally).
   - `noul` (the wire name for `:boolean` — `ReqLLM.Providers.TypeSafe`'s
     `normalize_question/1` already does this rewrite, so Planck's own
     schema keeps using `"boolean"` as the tool-facing discriminator):
     `criteria` **optional**, an object with `"true"`/`"false"` keys.

   This directly fixes [Phase 2](phase-2-planck-agent.md)'s
   `@classify_schema` — see that file for the corrected `oneOf`.

**`Planck.AI.Model`** (`planck_ai/lib/planck/ai/model.ex`):

- Add `@type provider :: :anthropic | :openai | :google | :typesafe`.
- Add `@type model_type :: :llm | :rlcd` and a `type: model_type()` field on
  `t()`, defaulting to `:llm` in `defstruct` (`type: :llm` alongside the
  existing `supports_thinking: false` etc., line 78-83).
- Add `:typesafe` to `@providers` (line 62). Note this list is a *second*
  copy of the provider atoms already declared in `Planck.AI.@providers`
  (`planck_ai.ex:44`) — both need the addition; pre-existing duplication,
  not introduced here.
- `type` defaults to `:llm` for every existing model-building path
  (`LLMDB.translate/1`, `Models.OpenAI.parse_model/3`) with no code change,
  since none of them set it explicitly today. `Config.build_from_config_entry/4`
  (`planck_ai/lib/planck/ai/config.ex:94-115`) **does** need an explicit
  `type: model_type(provider)` clause (`model_type(:typesafe) → :rlcd`,
  `model_type(_) → :llm`) — it's the one place a `:typesafe` model actually
  gets constructed from user config, and it builds a full `%Model{}` literal,
  so it would otherwise silently default to `:llm`.

**`Planck.AI.Models.TypeSafe`** (new, `planck_ai/lib/planck/ai/models/type_safe.ex`).
Unlike `Models.OpenAI` (which only queries live for the *compatible* path
and otherwise reads the bundled LLMDB catalog — there's no LLMDB catalog
for `:typesafe` at all), this provider queries `GET
"#{base_url}/v1/models"` **unconditionally**, cloud or self-hosted, since
both expose the same path per the confirmed contract above:

```elixir
defmodule Planck.AI.Models.TypeSafe do
  @behaviour Planck.AI.ModelProvider

  require Logger

  alias Planck.AI.Model

  @default_base_url "https://api.typesafe.ai"

  @impl Planck.AI.ModelProvider
  def all(opts \\ [])

  def all(opts) do
    base_url = opts[:base_url] || @default_base_url
    identifier = opts[:identifier] || "TYPESAFE"
    api_key = System.get_env("#{identifier}_API_KEY")
    req_opts = if api_key, do: [auth: {:bearer, api_key}], else: []

    case http_client().get("#{base_url}/v1/models", req_opts) do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        Enum.map(models, &parse_model(&1, base_url, opts))

      {:ok, %{status: status}} ->
        Logger.warning("[Planck.AI] typesafe endpoint returned HTTP #{status} from #{base_url}")
        []

      {:error, reason} ->
        Logger.warning("[Planck.AI] typesafe endpoint unreachable at #{base_url}: #{inspect(reason)}")
        []
    end
  end

  defp parse_model(%{"name" => name}, base_url, opts) do
    %Model{
      id: name, name: name, provider: :typesafe, type: :rlcd,
      identifier: opts[:identifier], base_url: base_url,
      context_window: opts[:context_window] || 32_768,
      max_tokens: opts[:max_tokens] || 2_048
    }
  end

  defp http_client, do: Application.get_env(:planck_ai, :http_client, Planck.AI.ReqHTTPClient)
end
```

Cloud calls (no `base_url:` given) resolve `TYPESAFE_API_KEY` the same way
`ReqLLM.Providers.TypeSafe`'s `default_env_key: "TYPESAFE_API_KEY"` does —
`identifier` only matters for a self-hosted/compatible `base_url` with its
own key, mirroring `:openai`'s `identifier` → `"#{identifier}_API_KEY"`
convention exactly. A self-hosted server without discovery (e.g. `decider`,
confirmed above) degrades to `[]` via the non-200/`:error` branches, same as
`Models.OpenAI.query_endpoint/2`'s own graceful failure — not a special
case, the same defensive pattern applied to a provider where "no discovery"
is a real, expected outcome rather than an edge case.

**`Planck.AI.list_providers/0`, `Planck.AI.list_models/2`** (`planck_ai.ex`):
add `:typesafe` to `@providers` (line 44) and a
`def list_models(:typesafe, opts), do: Models.TypeSafe.all(opts)` clause
(line 127-130), alias `Models.TypeSafe` alongside `Anthropic, Google, OpenAI`
(line 42).

**`Planck.AI.Adapter`** (`adapter.ex`) — evaluation doesn't go through
`to_req_llm/3` (that's chat-only: builds a `ReqLLM.Context`, adds tools,
etc.), but it needs the same model-spec-string construction. Extract nothing
new — add sibling clauses to the existing `build_model_spec/1` private
function (lines 56-70) and export a `model_spec/1` wrapper (or make
`build_model_spec/1` `@spec`'d and reused directly — implementation detail),
matching the `:openai` two-clause shape exactly:

```elixir
defp build_model_spec(%Model{provider: :typesafe, base_url: nil} = m) do
  "typesafe:#{m.model || m.id}"
end

defp build_model_spec(%Model{provider: :typesafe} = m) do
  %{provider: :typesafe, id: m.model || m.id}
end
```

And an `add_base_url/2` clause for `:typesafe`, copying the `:openai`
`has_api_key: false` / identifier-resolution pair (lines 88-100) verbatim
with `provider: :typesafe`.

**`Planck.AI.ReqLLMBehaviour`** (`req_llm_behaviour.ex`) — add:

```elixir
@callback evaluate(model_spec :: term(), state :: term(), questions :: term(), opts :: keyword()) ::
            {:ok, term()} | {:error, term()}
```

and the matching `Planck.AI.ReqLLM.evaluate/4` impl delegating to
`ReqLLM.evaluate/4`. `Planck.AI.MockReqLLM` (test support) gets the same
addition Mox needs for `stream_text/3` today.

**`Planck.AI.evaluate/4`** (new public function on `Planck.AI`, alongside
`stream/3`/`complete/3`):

```elixir
@spec evaluate(Model.t(), String.t() | map(), map()) :: {:ok, ReqLLM.Response.t()} | {:error, term()}
@spec evaluate(Model.t(), String.t() | map(), map(), keyword()) :: {:ok, ReqLLM.Response.t()} | {:error, term()}
def evaluate(%Model{} = model, state, questions, opts \\ []) do
  model_spec = Adapter.model_spec(model)
  req_opts = Adapter.evaluate_opts(model, opts)  # same add_base_url reuse as to_req_llm/3
  req_llm_client().evaluate(model_spec, state, questions, req_opts)
end
```

Returns the raw `ReqLLM.Response.t()` — `response.object` already carries the
answers map keyed by string per `ReqLLM.Evaluation`'s own moduledoc, no
reshaping needed at this layer.

## Use Cases

- A self-hosted setup (no cloud LLM budget for classification-shaped work)
  points `:typesafe`'s `base_url` at a local `decider` instance the same way
  `:openai`'s `base_url` already points at a local llama.cpp/Ollama instance.
- `Planck.AI.evaluate/4` gives any future caller — not just Phase 2's
  `classify` tool — a typed, Mox-testable way to call an RLCD model, the
  same shape `stream/3`/`complete/3` already give chat callers. `classify`
  is the first consumer, not the only one this API is designed for.

## Test Cases

- `model_test.exs` — `type` defaults to `:llm` when not set; a struct built
  with `type: :rlcd` round-trips; `:typesafe` is in `Model.providers/0`.
- `models_test.exs` — new `describe "TypeSafe.all/1"`. Cases: queries
  `"#{base_url}/v1/models"` (default `https://api.typesafe.ai` when no
  `base_url:` given) via `Planck.AI.MockHTTPClient`, same
  `expect(Planck.AI.MockHTTPClient, :get, fn ...)` pattern as OpenAI's
  base_url test (`describe "OpenAI.all/1"`, line 47-59); every returned
  model has `provider: :typesafe`, `type: :rlcd`, and the required fields
  (`id`, `context_window`, `max_tokens`); returns `[]` and logs a warning on
  a non-200 response (covers `decider`-like self-hosted servers with no
  discovery endpoint, confirmed as a real case, not hypothetical); returns
  `[]` on a connection error.
- `config_test.exs` — extend "accepts all three provider types" (line 169)
  to four; new test asserting a `"typesafe"` provider entry produces
  `type: :rlcd` and every other provider type still produces `type: :llm`
  — this is the one path (`build_from_config_entry/4`) that sets `type`
  explicitly rather than relying on the struct default, so it's the one
  place a regression could silently misclassify a model.
- `adapter_test.exs` — extend `describe "build_model_spec"` with a
  `:typesafe`-without-base_url case (mirrors "openai produces a
  provider:id string", line 39) and a `:typesafe`-with-base_url case
  (mirrors line 49's "bypass LLMDB lookup" case, renamed here to "bypass
  catalog lookup" since typesafe has no LLMDB catalog at all). Extend
  `describe "add_base_url"` with the same four `:typesafe` cases already
  covered for `:openai` (lines 93, 108, 116, 122): identifier-based env key
  resolution, default `TYPESAFE_API_KEY` fallback, `"not-needed"` when no
  key is resolvable, and `"not-needed"` forced by `has_api_key: false`.
- `ai_test.exs` — new `describe "evaluate/4"`, mirroring `describe
  "stream/3"`'s shape (lines 30-77): mocks `Planck.AI.MockReqLLM.evaluate/4`
  (no `test_helper.exs` change needed — `Mox.defmock(Planck.AI.MockReqLLM,
  for: Planck.AI.ReqLLMBehaviour)`, line 2, already picks up the new
  callback once it's added to the behaviour); asserts `state`/`questions`
  are forwarded unchanged; asserts `{:ok, response}` passes the raw
  `ReqLLM.Response.t()` through untouched (no reshaping at this layer, per
  this phase's design); asserts `{:error, reason}` propagates from the mock.
