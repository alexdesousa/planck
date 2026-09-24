# Phase 3 — `planck_headless`/`planck_agent`: system prompt for `classify`

Part of [v0.2.4-spec](../v0.2.4-spec.md). Depends on
[Phase 2](phase-2-planck-agent.md)'s `orchestrator_tools/6` and `classify`
tool.

## Objective

Give the system prompt the concrete language an agent needs to discover and
correctly use an RLCD model, since nothing else in the prompt teaches
Choice/Score/Boolean. `planck_headless` already passes
`store.available_models` to `orchestrator_tools/6` at all three of its call
sites, so `classify` gating and `list_models`' `type` field already reach
running agents as of Phase 2 — see the superseded-plan note below. What's
actually missing is `Planck.Agent.SystemPrompt` (in `planck_agent`) teaching
an agent about `classify` at all.

## Plan

**Superseded during Phase 2:** this phase's original plan called for
threading `store.available_models` into the three `Tools.worker_tools/3`
call sites in `planck_headless.ex`, so workers could get `classify` too.
That's no longer correct — Phase 2 settled on `classify` being
orchestrator-automatic only (gated in `orchestrator_tools/6`), with workers
only getting it via explicit `TEAM.json`/`spawn_agent` grant like any other
tool. `worker_tools/3` takes no `available_models` argument and never will;
nothing to wire here. `orchestrator_tools/6` already receives
`store.available_models` at all three of its call sites
(`start_orchestrator/6`, `start_workers/6`, `start_dynamic_worker/5`), so
the gating already reaches running agents with no further wiring needed.

No other changes needed here — `detect_available_models/0`
(`resource_store.ex:236-238`) already builds every model (including future
`:typesafe` entries) from `Config.providers!()`/`Config.models!()` via
`Planck.AI.Config.from_config/2`, which Phase 1 already covers.

**`list_models` tool output** — Phase 2 already added `type: m.type` to the
per-model map in `planck_agent/lib/planck/agent/tools.ex`'s `list_models/1`.

**`system_prompt.ex`** — this is the one place an agent actually learns
RLCD models and `classify` exist; spelling it out concretely rather than
leaving it as "add a tool section":

`@ordered_tools` (lines 36-47) gains `classify` right after `list_models`
(its precondition — you need to know a model's `type` before either
`spawn_agent` or `classify` can use it), and the grouping comment updates
from "discovery → spawn → interaction → management" to "discovery → decide →
spawn → interaction → management":

```elixir
@ordered_tools ~w(
  list_team
  list_skills
  load_skill
  list_models
  classify
  spawn_agent
  call_agent
  send_agent
  respond_agent
  interrupt_agent
  destroy_agent
)
```

`tool_section("list_models")` (lines 205-214) gains a line about `type`, so
an agent knows to check it before picking a model for either downstream
tool:

```elixir
defp tool_section("list_models") do
  """
  ### list_models

  Use before spawning a new agent to see which models are available, their IDs,
  and the base_url required for local providers. Your current model is marked
  `current: true`. Each model's `type` is `"llm"` (spawn_agent) or `"rlcd"`
  (classify) — check `type` before picking a model for either tool.
  """
  |> String.trim_trailing()
end
```

New `tool_section("classify")` clause, owning the discriminated-union
question shape rather than assuming the model already knows it. Shipped
with an H4 subsection per question type (own "when to use" guidance for
Choice/Score/Boolean, since they're not interchangeable) and no inline JSON
payload examples — the tool's own parameter schema already fully specifies
the exact shape per branch, so duplicating it in prose would just be a
second place to keep in sync:

```elixir
defp tool_section("classify") do
  """
  ### classify

  Use when you need a fast, calibrated decision — routing, extraction, a
  yes/no confidence check — instead of reasoning it out yourself in text.

  Call `list_models` first — only models with `type: "rlcd"` are valid.

  The result is a probability or chosen value per question, not prose — do
  not ask it to explain itself, and do not use it for anything that needs
  multi-step reasoning or tool use.

  Each entry in `questions` is one of three types — see the tool schema for
  exact fields:

  #### Choice

  Use when state fits into exactly one of a fixed set of named categories
  — routing to the right specialist, classifying an inbound message by
  intent. `criteria` names the options; the answer is the winning option's
  key and its probability.

  #### Score

  Use when state falls somewhere on an ordered scale rather than a
  discrete category — severity, quality, how well a draft matches a spec.
  `criteria` orders the scale low to high; the answer is a value across it.

  #### Boolean

  Use as a yes/no confidence gate before a destructive or irreversible
  action — "does this message clearly authorize a refund?" `criteria` is
  optional, clarifying what counts as yes/no; the answer is the
  probability the answer is yes.
  """
  |> String.trim_trailing()
end
```

The "not prose" point matters beyond phrasing: an RLCD model literally
cannot do chat (`ReqLLM.Providers.TypeSafe.attach_stream/4` errors
outright), so the prompt has to actively steer the agent away from
treating `classify` like a cheaper `call_agent`, not just describe its
happy path.

## Use Cases

- An operator adds a `"typesafe"` provider/model to `config.json`; the next
  session started (orchestrator, static workers, and dynamically spawned
  workers alike) automatically has `classify` available with no `TEAM.json`
  change — the same "just works" story `list_models`/`spawn_agent` already
  have for a newly configured chat model.
- An agent reads its own system prompt and learns, unprompted, that
  Choice/Score/Boolean questions exist and how to shape them — the calling
  human's task prompt doesn't need to explain `classify`'s question format
  itself.

## Test Cases

- `system_prompt_test.exs` (new file, in `planck_agent` — `system_prompt.ex`
  lives there, not in `planck_headless`; none of the four packages had a
  dedicated test for it before, `tool_section/1` and `@ordered_tools` were
  exercised only indirectly via `session_lifecycle_test.exs`'s system-prompt
  assertions). Shipped with full coverage of `SystemPrompt.build/1`, not
  just the classify/list_models additions: identity line (all `name`/`type`
  combinations), every `tool_section/1` clause (including unrecognized tool
  names being ignored), `@ordered_tools` ordering independent of tool-map
  insertion order, the `classify`/`list_models` `type` guidance and
  ordering, the inter-agent-tools intro's four `call_agent`/`send_agent`
  combinations, the skills section (pinned/ranked/empty), and the
  `prompt_hook` before/after prepend-append behavior (nil, default, string,
  empty-string).
- `session_lifecycle_test.exs` — "orchestrator has the classify tool when
  an rlcd model is configured" / "classify is absent from the orchestrator
  when no rlcd model is configured", covering `start_orchestrator/6`.
  Deliberately orchestrator-only, not "present on orchestrator and
  workers" — Phase 2 settled on `classify` never being automatic for
  workers, so there's nothing to test at `start_workers/6` or
  `start_dynamic_worker/5` beyond what `team_integration_test.exs`'s
  "classify gating" describe block already covers at the `planck_agent`
  unit level (`worker_tools/3` never includes `classify`; a spawned worker
  only gets it via explicit grant).
- `resource_store_test.exs` — extended "available_models is populated from
  providers + models config": added a `"typesafe"` provider entry to the
  fixture config and asserted the resulting `Planck.AI.Model` has
  `provider: :typesafe, type: :rlcd` — confirms this phase needs no
  special-casing here, since `detect_available_models/0` is already fully
  generic over `Planck.AI.Config.from_config/2`.
