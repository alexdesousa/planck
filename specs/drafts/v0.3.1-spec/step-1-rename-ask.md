# Step 1 — Hard rename `classify` → `ask`

Part of [v0.3.1-spec](../v0.3.1-spec.md). Depends on nothing.

## Description

Rename the `classify/1` tool builder to `ask/1`, tool `name:
"classify"` to `"ask"`, and `resolve_classify_model` to
`resolve_ask_model` in `planck_agent/lib/planck/agent/tools.ex`.
Schema, validation (`:rlcd`-only), and execution (thin wrapper over
`Planck.AI.evaluate/4`, `response.object` JSON-encoded) are unchanged.
Update `orchestrator_tools/6` docs, `system_prompt.ex`
(`tool_section("ask")`, `@ordered_tools`, `list_models` section which
references `(classify)`), `list_models` tool description, and every
test/fixture naming `classify`. No alias, no shim — unknown-tool
errors on old references are intended.

### TDD order

1. Rename + update all call sites; compile.
2. Update prompt-section tests, then tool tests.

## Definition of Done

- `grep -ri classify planck_agent/lib planck_headless/lib` (excluding
  CHANGELOG/history) returns zero hits.
- Orchestrator still auto-gets `ask` iff an `:rlcd` model is
  configured; workers still don't unless granted (Step 2 wires
  granting).
- `mix test` green in `planck_agent`.

## Use Cases

```gherkin
Feature: ask tool replaces classify with identical semantics

  Scenario: Orchestrator with an RLCD model receives ask
    Given available models include one with type "rlcd"
    When orchestrator tools are assembled
    Then the tool set contains "ask" and does not contain "classify"

  Scenario: Orchestrator without an RLCD model receives no ask tool
    Given available models contain only type "llm"
    When orchestrator tools are assembled
    Then the tool set contains neither "ask" nor "classify"

  Scenario: ask rejects non-RLCD models
    Given an "ask" call with a model_id of type "llm"
    When the tool executes
    Then it returns an error naming the model as not of type "rlcd"

  Scenario: Old classify references fail loudly
    Given an agent granted the tool name "classify"
    When tools resolve against the pool
    Then resolution yields nothing for that name
```

## Test Cases

- `orchestrator_tools/6` includes `ask` with RLCD present / excludes
  without (existing classify tests, renamed).
- `resolve_ask_model` accepts `:rlcd`, rejects `:llm` and unknown ids.
- System-prompt section renders for `ask`, absent without it.

## Files touched

- `planck_agent/lib/planck/agent/tools.ex`
- `planck_agent/lib/planck/agent/system_prompt.ex`
- `planck_agent/test/**` (rename coverage)
