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
- **No `@typesafe_compat_presets`** — decided against during implementation
  (see "Resolved during implementation" below): `decider` is too young a
  project to bake in as a named preset the way Ollama/llama.cpp are for
  OpenAI-compat, so `:typesafe_compat` gets no preset step at all, unlike
  `:openai_compat`.
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

**Resolved during implementation** — a few things the draft above got
slightly wrong or left unspecified:

- The argument `fetch_local_models/2` actually needs is the *real* provider
  atom (`:openai`/`:typesafe`), not `provider_type_for/1`'s return value
  (a string, used only for config persistence). Added a small
  `resolved_provider/1` helper (`:openai_compat -> :openai`,
  `:typesafe_compat -> :typesafe`) instead of reusing `provider_type_for/1`
  for this — a string-to-atom round trip through the wrong helper would
  work by accident today (both map to a real provider's own type string)
  but conflates two different concerns.
- **Base URL convention differs between the two local-provider families.**
  `req_llm`'s `TypeSafe` provider appends `/v1/systemone`/`/v1/models`
  itself (`default_base_url: "https://api.typesafe.ai"`, no `/v1` in it) —
  unlike OpenAI-compat, where `base_url` must already include `/v1`. The
  Base URL field's placeholder and help text are now provider-conditional
  (`base_url_placeholder/1`/`base_url_help/1`): OpenAI-compat keeps "Must
  include /v1 — e.g. http://localhost:11434/v1"; Typesafe-compat instead
  says "Server root, no path — e.g. http://localhost:8000". Getting this
  wrong would silently double up `/v1` in every self-hosted `decider` request.
- **No preset step for `:typesafe_compat` at all** (this draft originally
  guessed a `decider` preset with `has_api_key: true` — both wrong: decider
  is too young/unstable a project to bake in as a named preset, and a
  self-hosted default should lean toward `has_api_key: false` like
  `ollama`/`llama_cpp`, not `nvidia`/`groq`, if it existed). Instead,
  `:typesafe_compat` skips the preset picker and shows the Base
  URL/Identifier/API key form unconditionally — `:openai_compat` still
  requires picking a preset first, since that step exists specifically to
  prefill a known vendor's `base_url`/`identifier` defaults, and there are
  no known vendors yet for Typesafe-compatible servers. Revisit adding a
  preset list once a real self-hosted ecosystem exists here (decider or
  otherwise).
- `provider_api_key_env_var/2` (`planck_headless`) had no `"typesafe"`
  clause and silently dropped any Typesafe API key entered through the
  modal — see the Test Cases section below for the fix. Not something this
  phase's original plan anticipated; found because Phase 4 was the first
  thing to actually exercise a `:typesafe` provider through
  `configure_provider/1`.

## Use Cases

- A user configures a self-hosted `decider` (or any other Typesafe-wire-
  compatible) instance through the setup modal by picking
  Typesafe-compatible and typing in its URL directly — no preset to pick,
  no hand-editing `config.json`.
- A user adds Typesafe's cloud API the same way they'd add
  Anthropic/OpenAI/Google — pick the provider, paste an API key.

## Test Cases

- `provider_model_step_test.exs` (new file, `planck_cli` — the module had
  zero direct test coverage before this phase). Built as manually-constructed
  `%Phoenix.LiveView.Socket{}` + direct `handle_event/3`/`update/2` calls,
  the same technique `sidecar_widget_test.exs` already uses, rather than
  `live_isolated/3` — deliberately avoids ever reaching `do_save/1`'s real
  `config.json`/`.env` writes, since this component has no path-override
  seam for tests the way `Headless.configure_provider/1` itself does
  (`:local`/`:global` scope resolve to `.planck/config.json` and
  `~/.planck/config.json` with no override hook). Covers: the provider
  picker rendering `Typesafe`/`Typesafe-compatible` via `all_providers/0`;
  `provider_type_for/1`'s persistence mapping (made `def`, not `defp` — a
  minimal public accessor matching the module's existing pattern for
  `cloud_providers/0`/`local_providers/0`/`*_presets_data/0` — the safest
  way to test it without exercising the file-writing save path); that
  `:openai_compat` still requires a preset before advancing while
  `:typesafe_compat` does not; and that advancing with an empty `base_url`
  does not attempt a network fetch (`advance_to_model_step/1` takes the
  empty-list branch, not `fetch_local_models/2`). This last case also
  caught a real bug during writing: the template's preset-or-typesafe_compat
  guard used `and`/`or` on `@preset` (which is `nil`, not a boolean, before
  one is picked) — `Phoenix.LiveView.Diff` raised `BadBooleanError`
  immediately on render. Fixed by switching to `&&`/`||`.
- `model_controller_test.exs` — added "returns configured typesafe models"
  mirroring "returns configured local models". Decided during
  implementation: yes, `type` needed adding to the `ModelList` OpenAPI
  schema and `ModelController.index/2`'s response map — it was missing
  entirely (only `provider`/`id`/`context_window`/`base_url`), an
  inconsistency with `list_models`/`available_models` already surfacing
  `type` everywhere else in this release.
- New tests for `fetch_local_models/2`'s provider dispatch, folded into
  `provider_model_step_test.exs` above rather than a separate describe
  block.

### Bug found during implementation (not in the original plan)

`Planck.Headless.provider_api_key_env_var/2` (in `planck_headless`, not
`planck_cli`) had no clause for `"typesafe"` — it fell through to the
catch-all `nil`, so `configure_provider/1` would silently accept a
`:typesafe`/`:typesafe_compat` API key through the setup modal, write the
provider's `config.json` entry correctly, and then just drop the key
without persisting it to `.env` or the vault. Fixed by adding
`"typesafe"`/`<IDENTIFIER>`-based clauses mirroring `"openai"`'s, matching
`adapter.ex`'s `resolve_api_key(id || "TYPESAFE")` convention. Covered by
two new tests in `planck_headless/test/planck/headless/session_lifecycle_test.exs`
mirroring the existing `"openai"`/`"anthropic"` `.env`-writing tests.
