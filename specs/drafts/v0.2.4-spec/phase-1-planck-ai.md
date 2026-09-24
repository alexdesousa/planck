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
- Add `Model.types/0` (mirrors `providers/0`), returning `[:llm, :rlcd]`.
  Not originally planned — added alongside `providers/0` for symmetry
  during implementation. No caller yet beyond introspection, same role
  `providers/0` played before anything consumed it.
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

**`Planck.AI.list_types/0`** — not originally planned, added alongside
`list_providers/0` for the same reason as `Model.types/0` above: returns
`[:llm, :rlcd]`, no consumer yet.

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

**Type-guard invariant — not in the original plan, added during
implementation.** `stream/3`, `complete/3`, and `evaluate/4` each reject a
model of the wrong `type` outright, rather than letting a chat call reach
an RLCD model (or vice versa) and fail three layers down inside `req_llm`
with an opaque provider error. `stream/3`:

```elixir
def stream(model, context, opts \\ [])

def stream(%Model{} = model, %Context{} = context, opts) do
  case model.type do
    :llm ->
      # ...unchanged body...

    other ->
      raise ArgumentError,
            "model #{model.provider}:#{model.id} is type #{inspect(other)} — " <>
              "only :llm models support this call"
  end
end
```

`evaluate/4` mirrors this in the other direction (rejects everything but
`:rlcd`). `complete/3` needs no guard of its own — it calls `stream/3`
internally, which already raises.

This landed as a runtime `case` inside a single clause, not as two separate
`%Model{type: :llm}`/`%Model{type: :rlcd}`-guarded function clauses (the
first attempt at this). Elixir's compiler type checker can statically prove
a multi-clause, struct-pattern-guarded function's *total* domain from the
union of its clause patterns — with no catch-all clause, a call site
passing a provably-wrong-typed model (a literal struct built in a test, for
instance) fails to *compile* under this repo's `mix test --warnings-as-errors`,
not just to fail at runtime. That broke the tests written specifically to
verify the rejection. A `case` inside one clause is invisible to that
particular analysis, since it's runtime logic, not a set of clause
patterns — same reason `AgentSpec.resolve_model!/4`'s equivalent check
(see below) never had this problem.

## Use Cases

- A self-hosted setup (no cloud LLM budget for classification-shaped work)
  points `:typesafe`'s `base_url` at a local `decider` instance the same way
  `:openai`'s `base_url` already points at a local llama.cpp/Ollama instance.
- `Planck.AI.evaluate/4` gives any future caller — not just Phase 2's
  `classify` tool — a typed, Mox-testable way to call an RLCD model, the
  same shape `stream/3`/`complete/3` already give chat callers. `classify`
  is the first consumer, not the only one this API is designed for.

## Ripple fix — `planck_agent`'s `AgentSpec`

Not part of this phase's package, and not originally planned — a direct
consequence of this phase's own change, found during review and fixed
alongside it. Recorded here rather than in a phase file it doesn't belong
to (it isn't about the `classify` tool, so it's orthogonal to Phase 2).

Adding `:typesafe` to `Model.providers/0` silently made `"typesafe"` a
valid `provider` string in a `TEAM.json` member entry or a `spawn_agent`
call too, since `planck_agent/lib/planck/agent/agent_spec.ex`'s
`@provider_atoms` derives straight from `Planck.AI.Model.providers()`
(line 112). Nothing stopped an RLCD model from being configured as an
agent's *chat* model — it would only fail on that agent's first turn, as
the opaque `stream/3` rejection described above, three layers away from
the actual misconfiguration.

Fixed in `resolve_model!/4`, checked once after either resolution path
(declared in `available_models`, or looked up dynamically) produces a
model:

```elixir
defp resolve_model!(provider, model_id, base_url, available_models) do
  available_models
  |> Enum.find(&(&1.provider == provider && &1.id == model_id))
  |> case do
    nil ->
      resolve_model_dynamic!(provider, model_id, base_url)

    %Model{type: :llm} = declared ->
      declared

    %Model{type: other} ->
      raise ArgumentError,
            "model #{provider}:#{model_id} is type #{inspect(other)} — " <>
              "only :llm models are allowed"
  end
end
```

`resolve_model_dynamic!/3` carries the identical check for the live-lookup
branch, so both ways a model can reach an agent are covered.

**Considered and rejected**: hardcoding `provider in [:typesafe]` at this
layer. Fragile against any future provider that isn't uniformly one type,
and duplicates a fact (`:typesafe` → `:rlcd`) that already lives in exactly
one place, `Planck.AI.Config`'s `model_type/1`. Checking the *resolved
model's own* `type` field generically avoids a second provider list to
keep in sync anywhere else.

Test coverage: `agent_spec_test.exs` — raises when a model declared in
`available_models` is `type: :rlcd`; raises when a dynamically-resolved
model is `type: :rlcd`; both paths are tested since either can bypass the
other.

## Test Cases

- `model_test.exs` — `type` defaults to `:llm` when not set; a struct built
  with `type: :rlcd` round-trips; `:typesafe` is in `Model.providers/0`;
  `Model.types/0` returns `[:llm, :rlcd]`.
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
  Also new (for the type-guard invariant above): `stream/3`/`complete/3`
  raise `ArgumentError` for a non-`:llm` model; `evaluate/4` raises for a
  non-`:rlcd` model; `list_types/0` returns `[:llm, :rlcd]`. These
  "wrong-type" tests can't build the mismatched model as a literal
  struct-update (`%{@model | type: :rlcd}`) — the compiler's type checker
  proves it statically invalid and fails the build, the same class of
  problem the invariant itself is written around. They go through a
  `model_with/1` helper built on `struct!/2` instead, which the checker
  can't trace back to a literal field value.
- Test-hygiene fixes made to `adapter_test.exs`/`models_test.exs` along the
  way, not part of the original plan: `adapter_test.exs` was `async: false`
  and is now `async: true` (nothing in it touches global state that isn't
  already isolated); a `stash_env/1` helper was added and applied to every
  env-var mutation in `adapter_test.exs`, restoring each var's actual
  pre-test value in `on_exit` rather than assuming it started unset (so the
  suite doesn't clobber a real key a developer might have exported, e.g.
  a real `OPENAI_API_KEY`); the identifier-based tests
  (`NVIDIA_API_KEY`/`JEV_API_KEY`) in both files use a
  `System.unique_integer/1`-suffixed identifier, since those two var names
  were each mutated by both files under `async: true` — a real,
  reproducible cross-file race, not a hypothetical one.
