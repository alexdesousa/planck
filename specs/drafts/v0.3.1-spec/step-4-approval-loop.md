# Step 4 — Human-in-the-loop approval loop

Part of [v0.3.1-spec](../v0.3.1-spec.md). Depends on
[Step 3](step-3-hook-behaviours.md).

## Description

On `{:await_approval, reason}`: register the call in `turn.running`
as a parked entry (no task pid — `tool_done?/1` stays false,
turn pauses; status stays `:executing_tools` — whether approval is
pending is derived from the parked entries in `turn.running`, not
`status`), broadcast `:tool_blocked`, and park until a human resolves
it. New public API:

```elixir
Planck.Agent.approve_tool_call(agent, call_id)  # + Headless passthrough
Planck.Agent.deny_tool_call(agent, call_id, reason \\ nil)
```

Approve runs the stored `execute_fn` with the exact args seen at park
time, skipping `ToolStart` for that call only (`ToolEnd` still screens
the result). The entry is one-shot: approving or denying consumes it,
so a second call with the same `call_id` returns
`{:error, :not_found}` and nothing executes. Deny completes
`{:error, "denied …"}` as a plain string. Parallel parked calls
resolve independently. Rewind/stop drops parked entries silently (no
tool events, never resumed later).

v1 scope notes: no approval token (the stored closure fixes the args,
so approval cannot be redirected); no expiry sweeper (parked calls live
until approved/denied/session ends — per-gate timeouts are a follow-up,
owned sidecar-side); no `approval: :modal | :none` session flag (all
sessions park; API and UI clients approve through the same API); no UI
payload from `ToolStart` (gates return 2-tuples only — UI attachment
lives solely in `ToolEnd`, Step 5's `ApprovalTagger`).

### TDD order

1. Park/approve/deny state machine (no UI).
2. Stored-args approval + one-shot + gate-skip-once.
3. Parallel independence, rewind silent-drop.

## Definition of Done

- Full loop unit-tested without UI; `mix test` green in
  `planck_agent`, `planck_headless`.

## Use Cases

```gherkin
Feature: A parked tool call resumes exactly once on approval

  Scenario: Approve runs the exact parked call
    Given a parked "bash" call with args A
    When approve_tool_call is invoked with its call_id
    Then execute_fn runs once with args A and ToolStart is not consulted

  Scenario: Approval does not transfer to a different call
    Given a parked call approved and consumed
    When approve_tool_call is invoked again with the same call_id
    Then it fails and nothing executes

  Scenario: Deny ends the call as an error
    Given a parked call
    When deny_tool_call is invoked
    Then the turn continues with a "denied" error and no modal re-attaches

  Scenario: No expiry in v1 — parked calls wait for a human
    Given a parked call
    Then it stays parked until approved, denied, or the session ends

  Scenario: Parallel parked calls resolve independently
    Given two parked calls in one turn
    When one is approved and one denied
    Then the turn resumes with one executed result and one denial error

  Scenario: Rewind drops parked calls silently
    Given a parked call
    When the session rewinds
    Then the parked entry is dropped with no tool events, never resumed later
```

## Test Cases

- Stored-args approval, one-shot consumption,
  gate-skip-once verification (gate spy count), `ToolEnd` applied to
  approved results, rewind silent-drop.

## Files touched

- `planck_agent/lib/planck/agent.ex` (GenServer API,
  resume/deny paths)
- `planck_agent/lib/planck/agent/turn.ex` (parked entries in `running`)
- `planck_headless/lib/planck/headless.ex` (passthroughs)
