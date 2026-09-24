# Phase 2 — `planck_agent`: `classify` tool

Part of [v0.2.4-spec](../v0.2.4-spec.md). Depends on
[Phase 1](phase-1-planck-ai.md)'s `Planck.AI.evaluate/4` and `type` field.

## Objective

Add the `classify` tool itself — the agent-facing surface for RLCD models.
**Design changed from the original draft during implementation**: `classify`
is automatic for the orchestrator when at least one configured model has
`type: :rlcd` (same as `list_models`), but **not** automatic for workers —
a worker only gets it if explicitly granted, via `TEAM.json`'s `tools` list
or `spawn_agent`'s `tools:` param, the same way any other grantable tool
(built-in or sidecar) works. The original plan treated it as fully
automatic, alongside `call_agent`/`list_team`; that was deliberately
reversed — the orchestrator or a static `TEAM.json` should decide which
workers get it, not have it appear unconditionally everywhere an RLCD
model happens to be configured.

## Plan

**`Planck.Agent.Tools.classify/1`** (new, `tools.ex`), following the
`resolve_spawn_model/4` lookup pattern minus the live-fallback branch (a
classify model is always pre-configured, never queried live):

```elixir
@spec classify([Planck.AI.Model.t()]) :: Tool.t()
def classify(available_models) do
  Tool.new(
    name: "classify",
    description:
      "Use to get a fast, calibrated decision (routing, extraction, " <>
        "yes/no confidence) from an RLCD model instead of asking a general " <>
        "model to reason it out in text. Call list_models first and pass " <>
        "the id of a model with type \"rlcd\".",
    parameters: %{...the schema below, inline...},
    execute_fn: fn _agent_id, _id, args ->
      with {:ok, model} <- resolve_classify_model(args["model_id"], available_models),
           {:ok, response} <-
             AIBehaviour.client().evaluate(model, args["state"], args["questions"], []) do
        {:ok, Jason.encode!(response.object)}
      end
    end
  )
end

defp resolve_classify_model(model_id, available_models) do
  case Enum.find(available_models, &(&1.id == model_id and &1.type == :rlcd)) do
    %Planck.AI.Model{} = model -> {:ok, model}
    nil -> {:error, "no RLCD model configured with id #{inspect(model_id)}"}
  end
end
```

**Not in the original plan: calls `AIBehaviour.client().evaluate/4`, not
`Planck.AI.evaluate/4` directly.** `Planck.Agent.AIBehaviour` already wraps
`stream/3` and `get_model/2,3` so they're mockable via `Planck.Agent.MockAI`
in tests — it had no `evaluate/4` callback at all. Calling `Planck.AI`
directly would leave `classify` with no mockable seam in `planck_agent`'s
own test suite (`Planck.AI.MockReqLLM`, used for this in `planck_ai`'s own
tests, is defined in `planck_ai`'s `test/test_helper.exs` — test-only, not
reachable from a dependent package at all). Added
`@callback evaluate(Planck.AI.Model.t(), String.t() | map(), map(), keyword()) :: {:ok, Planck.AI.Evaluation.t()} | {:error, term()}`
to `ai_behaviour.ex`, matching the existing pattern exactly — no change
needed to the real implementation, since `Planck.AI.evaluate/4` already has
a matching signature and `AIBehaviour.client()` defaults to `Planck.AI`
itself in production. `Planck.AI.Evaluation.t()` is a new, tiny module in
`planck_ai` (`@type t :: ReqLLM.Response.t()`) — a name-only alias, not a
reshaped struct, added so this callback (and `Planck.AI.evaluate/4` itself)
reference a `Planck.AI`-owned type instead of `req_llm`'s directly, the
same boundary `Planck.AI.Stream.t()` already keeps for `stream/3`. The
error side stays `term()` deliberately, not tightened to
`ReqLLM.Error.t()`/`Exception.t()` — traced the actual `with` chain inside
`ReqLLM.Evaluation.evaluate/4` and it isn't uniform: `ReqLLM.model/1`
(one of the steps) has its own `@spec ... :: {:ok, LLMDB.Model.t()} |
{:error, term()}`, so claiming anything narrower here would be a claim
`req_llm` itself doesn't make.

**The schema is written inline in `parameters:`, not pulled into a
`@classify_schema` module attribute** — matching `spawn_agent/6`'s own
schema in this same file, which is also inline. An attribute would have
been functionally identical (Elixir module attributes are compile-time
constants, inlined at every use site either way) but inconsistent with the
established convention for a large per-tool schema in this module.

**Every property needs a `"description"` — this isn't a support
limitation, it was just incomplete in an earlier draft.** `"description"`
is a standard, non-validating JSON Schema keyword; `ExJsonSchema` ignores
it for validation but it's part of the same `parameters` map that gets
sent to the calling model as the tool's definition (exactly like every
property in `spawn_agent`'s own schema already has one). `model_id`,
`instructions`, and the discriminator `type` in each `oneOf` branch, and
the top-level `questions` object, all needed one and didn't have it:

```json
{
  "type": "object",
  "properties": {
    "model_id": {
      "type": "string",
      "description": "The id of an RLCD model to use, from list_models — only a model with type \"rlcd\" is valid. Call list_models first if you don't already have one."
    },
    "state": {
      "description": "The content to evaluate — plain text, or a JSON object/array for structured data such as a chat log or a record."
    },
    "questions": {
      "type": "object",
      "description": "Named typed questions to ask about state. Choose your own key for each question — its answer comes back under the same key.",
      "additionalProperties": {
        "oneOf": [
          {
            "properties": {
              "type": {"enum": ["choice"], "description": "Pick exactly one option from criteria."},
              "instructions": {"type": "string", "description": "What the model should decide between the given criteria options."},
              "criteria": {"type": "object", "description": "Option key -> description. Up to 255 options."}
            },
            "required": ["type", "instructions", "criteria"]
          },
          {
            "properties": {
              "type": {"enum": ["score"], "description": "Rate state against the ordered levels in criteria."},
              "instructions": {"type": "string", "description": "What the model should rate, in natural language."},
              "criteria": {"type": "array", "items": {"type": "string"}, "minItems": 2, "maxItems": 10, "description": "Ordered level descriptions, low to high."}
            },
            "required": ["type", "instructions", "criteria"]
          },
          {
            "properties": {
              "type": {"enum": ["boolean"], "description": "A yes/no question — returns the probability the answer is yes."},
              "instructions": {"type": "string", "description": "The yes/no question to evaluate, in natural language."},
              "criteria": {"type": "object", "properties": {"true": {"type": "string"}, "false": {"type": "string"}}, "description": "Optional — clarifies what counts as yes/no."}
            },
            "required": ["type", "instructions"]
          }
        ]
      }
    }
  },
  "required": ["model_id", "state", "questions"]
}
```

`"enum": ["choice"]` rather than `"const"` — safe under whichever draft
`ExJsonSchema.Schema.resolve/1` selects, since `enum` is valid in all three
supported drafts and `const` only from draft 6 on. Per-type field names
confirmed by Phase 1's Pre-work step against `docs.typesafe.ai`'s actual
API reference: all three types use `criteria`, just shaped differently —
an object for `choice`, an array for `score`, and an optional
`true`/`false`-keyed object for `boolean`/`noul`.

**Error-message follow-up — done, but scoped down from the original
ambition.** `Tool.format_schema_error/3` gains a clause matching
`ExJsonSchema`'s actual `oneOf` message text (checked directly against the
vendored `ex_json_schema` source, `validator/error/string_formatter.ex:164-173`
— it's `"Expected exactly one of the schemata to match, but none of them
did."`, not the paraphrase an earlier draft of this file guessed):

```elixir
defp format_schema_error(
       "Expected exactly one of the schemata to match, but none of them did.",
       "#/" <> key,
       _properties
     ) do
  "#{key}: does not match any of the allowed shapes for this field — check that all " <>
    "required fields for its type are present."
end
```

This is a real improvement (the existing generic catch-all clause already
prepends the failing key, e.g. `questions/department: <message>` — the new
clause only changes the message text itself to something actionable) but
**cannot name the specific missing field** the way the original plan
implied. `ExJsonSchema`'s default `Error.StringFormatter` collapses the
`%Error.OneOf{}` struct's per-branch sub-errors into that one flat string
before `format_schema_errors/2` ever sees it; getting the specific missing
field would mean calling `ExJsonSchema.Validator.validate/3` with
`error_formatter: false` and hand-rolling formatting for every error kind
`validate_args/2` currently delegates to the default formatter — a much
larger, riskier change to a function every tool in the system depends on,
not attempted here.

**Gating — automatic for the orchestrator only, in `orchestrator_tools/6`,
not in `worker_tools`.**

```elixir
def orchestrator_tools(session_id, team_id, available_models, grantable_tools \\ [], grantable_skills \\ [], cwd \\ "") do
  base = [
    spawn_agent(session_id, team_id, available_models, grantable_tools, grantable_skills, cwd),
    destroy_agent(team_id),
    interrupt_agent(team_id),
    list_models(available_models)
  ]

  if Enum.any?(available_models, &(&1.type == :rlcd)) do
    base ++ [classify(available_models)]
  else
    base
  end
end
```

`worker_tools/3` is **unchanged** — no new parameter, no gating logic; it
never included `classify` and doesn't now. For a worker to get `classify`,
it must be present in whatever `grantable_tools`/`tool_pool` gets passed
into `orchestrator_tools/6` and `AgentSpec.to_start_opts/2` — i.e. the same
list `read`/`bash`/sidecar tools already live in — and then named in
`TEAM.json`'s `"tools"` array or `spawn_agent`'s `tools:` param, exactly
like any other grantable tool. **`planck_headless` (Phase 3) is
responsible for adding `classify` to that pool when gated the same way**
(`Enum.any?(store.available_models, &(&1.type == :rlcd))`) — this phase
only makes the tool grantable in principle; wiring it into the actual pool
callers assemble is Phase 3's job, not done here.

No new race for the orchestrator-automatic case:
`Planck.Headless.ResourceStore`'s own moduledoc already commits to "loaded
once at startup... in-flight sessions are not affected by reloads", and
every tool-map assembly site reads `store.available_models` once, at
agent-start time, same as every other conditional tool.

**Confirmed while implementing this: no special-casing needed in
`system_prompt.ex` either way.** `append_tool_sections/2` filters
`@ordered_tools` purely by `Map.has_key?(tools, name)` — it has no concept
of role. Once Phase 3 adds a `tool_section("classify")` clause, it appears
for *any* agent that ends up with `classify` in its resolved tool map,
whether that's the orchestrator automatically or a worker granted it
explicitly. Nothing about the orchestrator/worker split above requires
touching that mechanism.

**Ripple fix — `spawn_agent`'s own model resolution also bypassed the
type guard, a second bypass beyond [Phase 1](phase-1-planck-ai.md)'s
`AgentSpec` fix.** `spawn_agent`'s `execute_fn` never goes through
`AgentSpec` at all — it builds start opts directly via
`build_spawn_start_opts/6` and calls `DynamicSupervisor.start_child`
straight, so the `AgentSpec.resolve_model!/4` fix doesn't cover it.
`resolve_spawn_model/4` had zero type checking. It currently *happens* to
be blocked by an accident, not a real safeguard: the tool's own JSON schema
hardcodes `"enum": ["anthropic", "openai", "google", "ollama", "llama_cpp",
"custom_openai"]` for `provider` — stale (`ollama`/`llama_cpp`/
`custom_openai` aren't real provider atoms in the current unified
provider-plus-`base_url` model, and `typesafe` was never added), so
`"typesafe"` gets rejected by schema validation before `execute_fn` runs
at all. That's incidental, not deliberate — fixing that obviously-stale
enum later (a very plausible, innocent-looking cleanup) would silently
reopen this exact gap. Fixed generically, mirroring `AgentSpec`'s fix:

```elixir
defp resolve_spawn_model(provider, model_id, base_url, available_models) do
  result =
    case Enum.find(available_models, &(&1.provider == provider and &1.id == model_id)) do
      %Planck.AI.Model{} = model -> {:ok, model}
      nil -> resolve_spawn_model_live(provider, model_id, base_url)
    end

  with {:ok, model} <- result, do: check_spawn_model_type(model)
end

defp check_spawn_model_type(%Planck.AI.Model{type: :llm} = model), do: {:ok, model}

defp check_spawn_model_type(%Planck.AI.Model{type: other, provider: provider, id: id}) do
  {:error,
   "Model #{provider}:#{id} is type #{inspect(other)} — only :llm models can be used as " <>
     "a worker's chat model. Call list_models and check each model's type before spawning."}
end
```

Unlike `AgentSpec.resolve_model!/4` (which raises — it runs at agent-start
time, deep in a pipeline with no caller expecting an error tuple), this
returns `{:error, reason}`, matching `spawn_agent`'s own existing `with`
chain (`validate_local_base_url/2` already returns `:ok`/`{:error, _}` in
the same chain).

**Noted, not fixed (out of scope for this phase): the stale `provider` enum
and `@local_providers` list.** `@local_providers` is `[:ollama, :llama_cpp,
:custom_openai]` — none of these are real provider atoms today (the
current system unifies "local" as any provider with a `base_url` override,
e.g. `:openai` + `base_url`). This predates this work and is unrelated to
RLCD/`classify` specifically; flagged here because it was found while
reading the same function, not because this phase fixes it.

**`list_models` gains `type`** (`tools.ex`) — done in this phase, not
deferred to Phase 3 as an earlier draft of the overall spec split it: same
file, same natural place to add it alongside `classify`.

```elixir
%{
  provider: m.provider,
  id: m.id,
  model: m.model,
  name: m.name,
  type: m.type,
  context_window: m.context_window,
  base_url: m.base_url,
  current: m.id == current_model_id
}
```

Update the moduledoc's tool table and `## Usage` example to reflect the
orchestrator-only automatic gating (not "all agents").

## Use Cases

- An orchestrator triages an inbound request ("is this a refund, a bug
  report, or spam?") with a `choice` question against a self-hosted `decider`
  model before spawning the specialist worker for the winning category —
  cheaper and lower-latency than asking a chat model to reason it out in
  prose and parse the answer back out.
- A worker about to take a destructive or irreversible action (delete,
  refund, escalate) runs a `boolean` question first ("does the user's message
  clearly authorize this?") and uses the returned probability as a confidence
  gate, instead of trusting its own free-text judgment — but only a worker
  the orchestrator or `TEAM.json` explicitly granted `classify` to, not
  every worker in the team by default.
- A large team with many workers uses `classify` for high-volume routing
  decisions without spending chat-model tokens (or latency) on each one —
  the orchestrator calls it directly, or grants it selectively to the
  specific workers whose job actually needs it.

## Test Cases

- `tool_test.exs` — new `describe "validate_args/2 with oneOf schemas
  (classify's questions)"`, built against `Tools.classify([])`'s real schema
  rather than a synthetic one. Cases: a valid `choice` question passes; a
  valid `score` question passes; a valid `boolean` question passes with and
  without its optional `criteria`; a `choice` missing `criteria` is
  rejected with the new actionable message (and explicitly *not* the raw
  `ExJsonSchema` "oneOf schemas" phrasing); an unrecognized `type` value is
  rejected.
- `tool_test.exs` — new `describe "Tools.classify/1"`, a focused unit test
  (build the tool directly, call `.execute_fn.(...)`, mock
  `Planck.Agent.MockAI.evaluate/4`) rather than through a live team. Cases:
  resolves `model_id` against `available_models` and forwards
  `state`/`questions` unchanged; returns `{:ok, Jason.encode!(response.object)}`
  on success; returns `{:error, ...}` when `model_id` doesn't match any
  available model; returns `{:error, ...}` when `model_id` matches an
  `:llm`-type model by id (the case most likely to be missed via a one-line
  `Enum.find` bug dropping the `type == :rlcd` guard); propagates
  `{:error, ...}` from `evaluate/4`.
- `tool_test.exs` — new `describe "Tools.list_models/1"`: output includes
  `type`, correctly `:llm`/`:rlcd` per source model.
- `team_integration_test.exs` — new describes:
  - `"spawn_agent rejects an :rlcd model as a worker's chat model"` — the
    `resolve_spawn_model`/`check_spawn_model_type` ripple fix, called
    directly through `spawn_tool.execute_fn.(...)` (bypassing the tool's
    own stale `provider` enum, which would otherwise mask this at the
    schema-validation layer before `execute_fn` ever ran).
  - `"classify gating"` — `orchestrator_tools/6` includes `classify` when
    an `:rlcd` model is available, omits it otherwise; `worker_tools/3`
    never includes it regardless; a dynamically-spawned worker does *not*
    receive it automatically even with an `:rlcd` model configured; a
    dynamically-spawned worker *does* receive it when granted via
    `spawn_agent`'s `tools:` param, the same as any other grantable tool.
