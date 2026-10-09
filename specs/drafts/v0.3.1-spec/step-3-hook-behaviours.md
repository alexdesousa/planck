# Step 3 — `ToolStart` / `ToolEnd` / `TurnStart` hook behaviours + pipeline

Part of [v0.3.1-spec](../v0.3.1-spec.md). Depends on nothing
(buildable in parallel with Steps 1–2; needed by Step 4).

## Description

Three new behaviours following the existing hook pattern (`use`
macro, `*_timeout/0`, `ensure_loaded` + `:rpc.call` dispatch,
fail-open on `:badrpc`):

```elixir
ToolStart.proceed(agent_id, tool_name, args) ->
  :ok | {:deny, reason} | {:await_approval, reason}   # default: :ok
ToolEnd.transform(agent_id, tool_name, args, result) ->
  {:ok, text} | {:ok, text, %{ui:}} | {:error, reason} | {:error, reason, %{ui:}}  # default: identity
TurnStart.notify(agent_id, session_id) -> :ok          # default: :ok
```

Pipeline per tool call becomes **validate → gate → execute →
loop-nudge → transform → UI extraction** (`Turn.prepare_call` /
`start_tool_task` in `agent.ex`, `turn.ex`). Validation stays first
so schema-invalid calls never spend an RLCD evaluation. `nil` hook =
current code path, zero overhead. `ToolStart`/`ToolEnd` are
**synchronous** (tight timeouts, fail-open to `:ok`/identity);
`TurnStart` is a background Task like `TurnEnd.reflect`. `Prompt`
remains the sole sync prompt injector — `TurnStart` is observer-only.

Result type gains `{:error, reason, %{ui: ui_content()}}`;
`finish_tool_execution` extracts `%{ui:}` from error triples exactly
like ok triples. New `:tool_blocked` PubSub event (+ API schema
entry) broadcast when a gate denies or parks. `Hooks` struct gains
`tool_start/tool_end/turn_start` fields; TEAM.json gains
`tool_start_hook/tool_end_hook/turn_start_hook`; `AgentSpec` +
`headless` thread them like the existing four.

## Definition of Done

- Unconfigured agents execute byte-identical paths (no extra latency,
  no new RPCs).
- `mix test` green in `planck_agent` (+ headless wiring tests).

### TDD order

1. Behaviours + defaults (nil/no-hook passthrough).
2. Pipeline order + error+UI extraction + `:tool_blocked`.
3. RPC dispatch + timeouts + fail-open (badrpc → proceed/identity).

## Use Cases

```gherkin
Feature: ToolStart gates and ToolEnd transforms in pipeline order

  Scenario: No hooks configured changes nothing
    Given an agent with no tool hooks
    When any tool executes
    Then validation, execution, and result handling behave exactly as before

  Scenario: ToolStart denies a call
    Given a ToolStart hook returning {:deny, "reason"}
    When the agent calls the gated tool
    Then execute_fn never runs
    And the agent sees an error containing "reason" plus the do-not-work-around notice
    And a :tool_blocked event broadcasts

  Scenario: ToolStart rewrites args
    Given a hook returning {:proceed, new_args}
    When the tool executes
    Then execute_fn receives new_args

  Scenario: ToolEnd attaches UI to an error
    Given a ToolEnd hook returning {:error, reason, %{ui: content}}
    When the tool fails
    Then the agent sees the error text and the UI layer receives the side effect

  Scenario: RPC failure fails open
    Given a configured hook whose sidecar is unreachable
    When a tool executes
    Then the call proceeds and the result is untransformed, with a warning logged

  Scenario: TurnStart never blocks or injects
    Given a slow TurnStart hook
    When a turn begins
    Then the LLM request is unaffected and the prompt is unchanged
```

## Test Cases

- Pipeline order incl. validate-first; loop-nudge preserved;
  error-triple UI extraction; `:tool_blocked` payload.
- Timeouts: slow gate → proceed; slow transform → identity.
- TEAM.json string → atom resolution for the three new fields.

## Files touched

- `planck_agent/lib/planck/agent/hooks/{tool_start,tool_end,turn_start}.ex` (new)
- `planck_agent/lib/planck/agent/hooks.ex`, `tool.ex`, `turn.ex`, `agent.ex`
- `planck_agent/lib/planck/agent/agent_spec.ex` (or headless wiring)
- `planck_cli/lib/planck/web/api/schemas.ex` (`:tool_blocked`)
