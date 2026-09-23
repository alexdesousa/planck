# Phase 2 — `planck_agent`: `classify` tool

Part of [v0.2.4-spec](../v0.2.4-spec.md). Depends on
[Phase 1](phase-1-planck-ai.md)'s `Planck.AI.evaluate/4` and `type` field.

## Objective

Add the `classify` tool itself — the agent-facing surface for RLCD models —
gated on at least one configured `:rlcd` model, and available automatically
to every agent (orchestrator and worker alike) the same way
`list_team`/`call_agent` already are, not as a sidecar tool requiring
`TEAM.json` opt-in.

## Plan

**`Planck.Agent.Tools.classify/1`** (new, `tools.ex`), following the
`resolve_spawn_model/4` lookup pattern (lines 602-609) minus the live-fallback
branch (a classify model is always pre-configured, never queried live):

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
    parameters: @classify_schema,
    execute_fn: fn _agent_id, _id, args ->
      with {:ok, model} <- resolve_classify_model(args["model_id"], available_models),
           {:ok, response} <- Planck.AI.evaluate(model, args["state"], args["questions"]) do
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

`@classify_schema` — `model_id` (string), `state` (string or object — the
thing being classified), `questions` (object, name → typed question).
**No separate casting layer (Ecto or otherwise) is needed for Choice / Score
/ Noul — the JSON Schema itself, validated automatically, is enough.**
`Planck.Agent.Tool.validate_args/2` (`tool.ex:108-122`) already runs every
tool's `args` through `ExJsonSchema` before `execute_fn` is invoked, and the
vendored `ex_json_schema` (0.11.5, draft 6/7) supports `oneOf` — so each
question's three shapes are expressed as a discriminated union keyed on
`"type"`, and get rejected before `Planck.AI.evaluate/4` is ever called,
using infrastructure already in `classify`'s own dispatch path:

```json
{
  "type": "object",
  "properties": {
    "model_id": {"type": "string"},
    "state": {"description": "Text or JSON object being classified."},
    "questions": {
      "type": "object",
      "additionalProperties": {
        "oneOf": [
          {
            "properties": {
              "type": {"enum": ["choice"]},
              "instructions": {"type": "string"},
              "criteria": {"type": "object", "description": "Option key -> description. Up to 255 options."}
            },
            "required": ["type", "instructions", "criteria"]
          },
          {
            "properties": {
              "type": {"enum": ["score"]},
              "instructions": {"type": "string"},
              "criteria": {"type": "array", "items": {"type": "string"}, "minItems": 2, "maxItems": 10, "description": "Ordered level descriptions, low to high."}
            },
            "required": ["type", "instructions", "criteria"]
          },
          {
            "properties": {
              "type": {"enum": ["boolean"]},
              "instructions": {"type": "string"},
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
supported drafts and `const` only from draft 6 on. **Per-type field names
confirmed** by [Phase 1](phase-1-planck-ai.md)'s Pre-work step, against
`docs.typesafe.ai`'s actual API reference (not a guess from the one
`req_llm` example an earlier draft of this file used — that draft had
`score` using a `levels` field, which was wrong): all three types use
`criteria`, just shaped differently — an object for `choice`, an array for
`score`, and an optional `true`/`false`-keyed object for `boolean`/`noul`.
`ReqLLM.Evaluation.validate_questions/1` itself only checks shape (`is_map`),
not field names — question validation is entirely provider-side; the schema
above is Planck's own pre-flight check, matching the confirmed wire contract
rather than mirroring anything `req_llm` itself enforces.

**Error-message follow-up.** `Tool.format_schema_error/3` (tool.ex:126-135)
has a special case for `enum` failures but none for `oneOf` — today, a
malformed question (e.g. a `choice` missing `criteria`) would surface
`ExJsonSchema`'s generic "does not match any of the oneOf schemas" to the
model instead of "choice requires `criteria`." Add a `oneOf`-aware clause
there so `classify`'s rejections are actually actionable for the calling
agent, not just correctly rejected.

**Gating — `worker_tools/3` → `worker_tools/4`.** `classify` is not a
sidecar/`TEAM.json`-opt-in tool; it belongs with the other automatic
inter-agent tools (`call_agent`/`send_agent`/`respond_agent`/`list_team`),
available to orchestrator and worker alike, same as `list_models` is
automatic for orchestrators. Add an `available_models` parameter (default
`[]`) to `worker_tools/3` (`tools.ex:50-57`):

```elixir
@spec worker_tools(String.t(), String.t() | nil, map() | nil, [Planck.AI.Model.t()]) :: [Tool.t()]
def worker_tools(team_id, delegator_id, sender \\ nil, available_models \\ []) do
  base = [call_agent(team_id), send_agent(team_id), respond_agent(delegator_id, sender), list_team(team_id)]
  if Enum.any?(available_models, &(&1.type == :rlcd)), do: base ++ [classify(available_models)], else: base
end
```

No new race: `Planck.Headless.ResourceStore`'s own moduledoc already commits
to "loaded once at startup... in-flight sessions are not affected by
reloads" (`resource_store.ex:1-16`), and every tool-map assembly site reads
`store.available_models` once, at agent-start time, same as every other
conditional tool. Gating `classify`'s presence this way is safe by
construction — confirmed during design, not deferred.

Update the moduledoc's tool table (line 24-33) and `## Usage` example
(lines 9-20).

## Use Cases

- An orchestrator triages an inbound request ("is this a refund, a bug
  report, or spam?") with a `choice` question against a self-hosted `decider`
  model before spawning the specialist worker for the winning category —
  cheaper and lower-latency than asking a chat model to reason it out in
  prose and parse the answer back out.
- A worker about to take a destructive or irreversible action (delete,
  refund, escalate) runs a `boolean` question first ("does the user's message
  clearly authorize this?") and uses the returned probability as a confidence
  gate, instead of trusting its own free-text judgment.
- A large team with many workers uses `classify` for high-volume routing
  decisions without spending chat-model tokens (or latency) on each one.

## Test Cases

- `tool_test.exs` — new `describe "validate_args/2 with oneOf schemas"`.
  This is genuinely new ground: nothing in the suite today exercises a
  `oneOf` schema through `validate_args/2` (existing `validate_args`
  coverage lives in `builtin_tools_test.exs`, against flat `properties`
  schemas only). Cases: a valid `choice` question passes; a valid `score`
  question passes; a valid `boolean` question passes; a `choice` missing
  `criteria` is rejected; an unrecognized `type` value is rejected; once
  `format_schema_error/3`'s `oneOf` clause (the follow-up above) is added,
  assert the rejection message actually names the missing field rather than
  surfacing `ExJsonSchema`'s generic "does not match any of the oneOf
  schemas" — this last case is what pins the follow-up in place so it can't
  silently regress.
- New tests for `Tools.classify/1` itself — as a focused unit test (build
  the tool directly and call `.execute_fn.(...)` with `Planck.AI.MockReqLLM`
  mocked) rather than through a live team, since nothing here needs real
  agent processes. Cases: resolves `model_id` against `available_models`
  and calls `Planck.AI.evaluate/4` with `state`/`questions` passed through
  unchanged; returns `{:ok, Jason.encode!(response.object)}` on success;
  returns `{:error, ...}` when `model_id` doesn't match any model in
  `available_models`; returns `{:error, ...}` when `model_id` matches an
  `:llm`-type model by id (must reject — a chat model is not a valid
  classify target even if the id exists) — this is the case most likely to
  be missed since it's an easy one-line `Enum.find` bug
  (`&(&1.id == model_id)` instead of `&(&1.id == model_id and &1.type ==
  :rlcd)`); returns `{:error, ...}` when `Planck.AI.evaluate/4` itself
  errors.
- `worker_tools/4` gating — there's no dedicated unit test file for
  `Planck.Agent.Tools` today (`worker_tools`/`orchestrator_tools` are
  exercised only through `team_integration_test.exs`'s live-team setup, e.g.
  lines 70-71/299); add cases there alongside the existing "spawn_agent
  grantable tools"/"destroy_agent" describes (lines 519, 456): `classify` is
  present in both the orchestrator's and a worker's tool list when
  `available_models` contains a `type: :rlcd` entry; absent from both when
  it doesn't (including the default `available_models: []` case, so a
  caller that forgets to pass the new 4th arg doesn't crash — just degrades
  to today's behavior).
- `list_models` tool — extend wherever its JSON output is currently
  asserted (via the live-team setup in `team_integration_test.exs`, same as
  `spawn_agent`) to check the new `"type"` field is present and correctly
  `"rlcd"`/`"llm"` per source model, not just that the tool runs.
