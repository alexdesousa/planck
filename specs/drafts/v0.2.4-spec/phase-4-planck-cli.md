# Phase 4 — `planck_cli`: setup modal

Part of [v0.2.4-spec](../v0.2.4-spec.md). Depends on
[Phase 1](phase-1-planck-ai.md)'s `:typesafe` provider (the config `type`
string this phase's UI writes must match what `Planck.AI.Config.parse_provider/1`
accepts).

## Objective

Let a user configure a Typesafe (cloud) or Typesafe-compatible (self-hosted,
e.g. `decider`) provider through the setup modal, mirroring the existing
`:openai` / `:openai_compat` split exactly — a real provider atom for the
cloud case, plus a UI-only local-provider atom that persists as the same
config `type` string, differing only by `base_url`.

## Plan

`provider_model_step.ex`:

- `@cloud_providers` (line 20): add `:typesafe`.
- `@local_providers` (line 21): add `:typesafe_compat`.
- New `@typesafe_compat_presets` (mirrors `@openai_compat_presets`, lines
  24-30) — likely just `{"decider", "decider (self-hosted)", "", nil, true}`
  and `{"other", "Other", "", nil, true}`; there's no known multi-vendor
  ecosystem here yet the way NVIDIA/Groq/Ollama exist for OpenAI-compat.
- `provider_type_for/1` (line 660-664): add
  `defp provider_type_for(:typesafe_compat), do: "typesafe"`.
- `provider_label/1` (line 708+), `credential_label/1` (line 700-703),
  `credential_placeholder/1` (705-706), `compute_provider_key/3` (588-600),
  `all_providers/0` (715-719), `cloud_provider?/1` (698): add the two new
  atoms alongside their `:openai`/`:openai_compat` counterparts throughout.

**Model sub-step — resolved.** The manual-entry fallback already exists and
is fully generic (`provider_model_step.ex:919-946`): the model field renders
a `<.dropdown>` when `@models != []` and a plain free-text `<input
name="model_api_id">` (placeholder `"llama3.2"`, helper text "Exact model
identifier as it appears in the provider API.") otherwise — driven purely
by whether the list came back empty, not by which provider it is. A
`decider` instance returning `[]` from a missing `/v1/models` lands in the
exact same already-working branch Ollama/llama.cpp hit today when their own
`/models` query fails. Nothing new needed in the template.

Two things upstream of the template **do** need wiring, though — the spec
draft here previously left this as an open question, but the fallback
existing doesn't mean the wiring is automatic:

- `load_models/1` (line 460) hardcodes `provider in [:anthropic, :openai,
  :google]` for the cloud-catalog branch — add `:typesafe`, or the *cloud*
  Typesafe catalog (which does have `/v1/models`, confirmed in
  [Phase 1](phase-1-planck-ai.md)) incorrectly falls to the
  empty-list/manual-entry branch instead of listing real models.
- `fetch_local_models/1` (line 469) is hardcoded to
  `Planck.AI.list_models(:openai, base_url: base_url)` — it takes no
  provider argument at all. Generalize to `fetch_local_models(provider,
  base_url)`, dispatching `Planck.AI.list_models(provider, base_url:
  base_url)`, so `:typesafe_compat` actually queries `:typesafe`'s endpoint
  instead of silently querying OpenAI's. Both call sites need the extra
  argument threaded through: `advance_to_model_step/1` (already has
  `a.provider` in scope) and `load_models_for_provider_key/1` (line 490,
  already resolves `provider` from the persisted config's `type` string via
  `String.to_existing_atom(type)` — that's already `"typesafe"` for both
  `:typesafe` and `:typesafe_compat` per `provider_type_for/1`, so this call
  site just needs the argument added, no new resolution logic).

## Use Cases

- A user configures a self-hosted `decider` instance through the setup
  modal the same way they'd add a local llama.cpp endpoint today — no
  hand-editing `config.json`.
- A user adds Typesafe's cloud API the same way they'd add
  Anthropic/OpenAI/Google — pick the provider, paste an API key.

## Test Cases

- New test(s) for `fetch_local_models/2`'s provider dispatch (whatever
  `describe` block ends up covering `provider_model_step.ex` — see the gap
  noted below): selecting `:typesafe_compat` with a `base_url` queries
  `Planck.AI.list_models(:typesafe, base_url: ...)`, not `:openai` — this
  is exactly the bug the hardcoded `:openai` call would otherwise produce
  silently (a `decider` server would get queried with an OpenAI-shaped
  request and simply return `[]`, masking the real defect as "no discovery
  endpoint" instead of "wrong provider called"). Also: selecting `:typesafe`
  (cloud, no `base_url`) goes through `load_models/1`'s cloud-catalog
  branch, not the empty-list fallback — catches the case where `:typesafe`
  is missed from that guard clause.
- `model_controller_test.exs` — mirror the existing "returns configured
  local models" test (`Application.put_env(:planck, :providers, ...)` with
  `"type" => "openai"`, then reload + assert via `GET /api/models`): add
  "returns configured typesafe models" with `"type" => "typesafe"`. Check
  whether the `ModelList` OpenAPI schema (asserted via `assert_schema(body,
  "ModelList", api_spec())`) needs a `type` field added if `type` is meant
  to surface over this HTTP API too, not just the `list_models` tool —
  confirm during implementation, since the schema is a separate contract
  from the tool's own JSON shape.
- `provider_model_step.ex` has **no existing test file** — unlike
  `model_controller_test.exs`, this module has zero direct test coverage
  today (confirmed by listing `planck_cli/test`; no `setup_modal` path
  exists there). This is a real gap to name rather than paper over:
  implementing this phase means either (a) writing the first
  `Phoenix.LiveViewTest`-based test file for this module — covering the
  provider picker rendering `:typesafe`/`:typesafe_compat` as options via
  `all_providers/0`, `provider_type_for/1`'s persistence mapping producing
  `"typesafe"` for both, and the preset-selection flow for
  `:typesafe_compat` — or (b) leaving it manually-QA'd the way it
  apparently is today, and not raising the testing bar unilaterally within
  this one change. Flag this as a decision to make explicitly rather than
  assume either way.
