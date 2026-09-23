# Phase 3 — `planck_headless`: thread `available_models` through + system prompt

Part of [v0.2.4-spec](../v0.2.4-spec.md). Depends on
[Phase 2](phase-2-planck-agent.md)'s `worker_tools/4` and `classify` tool.

## Objective

Wire `available_models` through to every place `planck_headless` builds an
agent's tool list, so Phase 2's `classify` gating and the new `type` field
on `list_models` actually reach running agents — and give the system prompt
the concrete language an agent needs to discover and correctly use an RLCD
model, since nothing else in the prompt teaches Choice/Score/Noul.

## Plan

Three call sites in `planck_headless.ex` call `Tools.worker_tools/3` today
and already have `store.available_models` in scope — add it as the 4th arg
to all three:

- `start_orchestrator/6`, line 635: `Tools.worker_tools(team_id, nil)` →
  `Tools.worker_tools(team_id, nil, nil, store.available_models)`.
- `start_workers/6`, line 709: `Tools.worker_tools(team_id, orchestrator_id, sender)` →
  add `, store.available_models`.
- `start_dynamic_worker/5` (the `spawn_agent` runtime path), line 931: same.

No other changes needed here — `detect_available_models/0`
(`resource_store.ex:236-238`) already builds every model (including future
`:typesafe` entries) from `Config.providers!()`/`Config.models!()` via
`Planck.AI.Config.from_config/2`, which Phase 1 already covers.

**`list_models` tool output** (`tools.ex:451-481`) — add `type: m.type` to
the per-model map (line 467-476).

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
question shape rather than assuming the model already knows it:

```elixir
defp tool_section("classify") do
  """
  ### classify

  Use when you need a fast, calibrated decision — routing, extraction, a
  yes/no confidence check — instead of reasoning it out yourself in text.
  Call `list_models` first and pass the `id` of a model with `type: "rlcd"`.

  Each entry in `questions` is one of:

  - `{"type": "choice", "instructions": "...", "criteria": {"key": "description", ...}}`
  - `{"type": "score", "instructions": "...", "criteria": ["low description", "...", "high description"]}`
  - `{"type": "boolean", "instructions": "..."}` (optionally `"criteria": {"true": "...", "false": "..."}`)

  The result is a probability or chosen value per question, not prose — do
  not ask it to explain itself, and do not use it for anything that needs
  multi-step reasoning or tool use.
  """
  |> String.trim_trailing()
end
```

This last point matters beyond phrasing: an RLCD model literally cannot do
chat (`ReqLLM.Providers.TypeSafe.attach_stream/4` errors outright), so the
prompt has to actively steer the agent away from treating `classify` like a
cheaper `call_agent`, not just describe its happy path.

## Use Cases

- An operator adds a `"typesafe"` provider/model to `config.json`; the next
  session started (orchestrator, static workers, and dynamically spawned
  workers alike) automatically has `classify` available with no `TEAM.json`
  change — the same "just works" story `list_models`/`spawn_agent` already
  have for a newly configured chat model.
- An agent reads its own system prompt and learns, unprompted, that
  Choice/Score/Noul questions exist and how to shape them — the calling
  human's task prompt doesn't need to explain `classify`'s question format
  itself.

## Test Cases

- `system_prompt_test.exs` (new file — none of the four packages currently
  has one; `tool_section/1` and `@ordered_tools` are exercised only
  indirectly today via `session_lifecycle_test.exs`'s system-prompt
  assertions). Test cases: `classify`'s section only appears in `build/1`'s
  output when `"classify"` is in the agent's `tools` list; `list_models`'s
  section text includes the `type` guidance; section ordering places
  `classify` immediately after `list_models` and before `spawn_agent` when
  all three are present.
- `session_lifecycle_test.exs` — mirror "load_skill is absent when no
  skills exist" / "present when skills exist" (lines 238, 268): new tests
  "classify tool and system-prompt section are present on orchestrator and
  workers when an rlcd model is configured" and "...absent when no rlcd
  model is configured", covering `start_orchestrator`/`start_workers` (this
  phase's other two call sites). The `start_dynamic_worker` path (runtime
  `spawn_agent`) is exercised instead via `team_integration_test.exs`'s
  existing "spawn_agent grantable tools" describe block (planck_agent, line
  519), since that's where dynamic worker spawning is already tested.
- `resource_store_test.exs` — extend "available_models is populated from
  providers + models config" (line 98): add a `"typesafe"` provider entry
  to the fixture config and assert the resulting `Planck.AI.Model` has
  `provider: :typesafe, type: :rlcd` — confirms this phase needs no
  special-casing here, since `detect_available_models/0` is already fully
  generic over `Planck.AI.Config.from_config/2`.
