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

**Open question, model sub-step.** The model sub-step for `:openai_compat`
queries the server's live `/models` endpoint (mirroring
`Models.OpenAI.query_endpoint/2`). Whether `:typesafe_compat` gets the same
live query depends on Phase 1's open question (does a listing endpoint
exist at all) — if not, the model sub-step needs to fall back to manual
model-id entry. Check whether that fallback path already exists in
`provider_model_step.ex` for providers without discovery, or needs adding.

## Use Cases

- A user configures a self-hosted `decider` instance through the setup
  modal the same way they'd add a local llama.cpp endpoint today — no
  hand-editing `config.json`.
- A user adds Typesafe's cloud API the same way they'd add
  Anthropic/OpenAI/Google — pick the provider, paste an API key.

## Test Cases

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
