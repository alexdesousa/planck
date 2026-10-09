# Step 4 — Human-in-the-loop approval loop

Part of [v0.3.1-spec](../v0.3.1-spec.md). Depends on
[Step 3](step-3-hook-behaviours.md).

## Description

On `{:await_approval, reason}`: register the call in `turn.running`
as `:awaiting_approval` (no task pid — `tool_done?/1` stays false,
turn pauses), store `{tool, args}` in a `pending_approvals` map keyed
by `call_id`, broadcast `:tool_blocked`, and surface the tagged error
to `ToolEnd` for UI. New public API:

```elixir
Planck.Agent.approve_tool_call(agent, call_id)  # + Headless passthrough
Planck.Agent.deny_tool_call(agent, call_id, reason \\ nil)
```

Approve verifies a one-shot token bound to the exact
`(tool_name, args-hash)` — approving one command never authorizes a
different one — deletes it, then runs `execute_fn` skipping
`ToolStart` for that call only (`ToolEnd` still screens the result).
Deny/expiry completes `{:error, "denied …"}` as a plain string (no
re-modal). Expiry (default 5 min, configurable) auto-denies so turns
never wedge; parallel parked calls resolve independently. Sessions
carry `approval: :modal | :none` from start (CLI passes `:modal`);
`:none` degrades await-approval to immediate deny text without
parking. Session stop/rewind denies all parked entries.

### TDD order

1. Park/approve/deny state machine (no UI).
2. Token binding + one-shot + gate-skip-once.
3. Expiry, `:none` degradation, stop/rewind deny-all.

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

  Scenario: Expiry auto-denies
    Given a parked call past its expiry
    When the sweeper runs
    Then the call completes as denied and the turn continues

  Scenario: Non-UI session never parks
    Given a session with approval :none
    When the gate returns await_approval
    Then the agent immediately sees a deny error and the turn continues

  Scenario: Parallel parked calls resolve independently
    Given two parked calls in one turn
    When one is approved and one denied
    Then the turn resumes with one executed result and one denial error

  Scenario: Session stop denies parked calls
    Given a parked call
    When the session stops
    Then the parked entry is denied, never resumed later
```

## Test Cases

- Token binding (mutated args rejected), one-shot consumption,
  gate-skip-once verification (gate spy count), `ToolEnd` applied to
  approved results, expiry sweep, `:none` path, deny-all on stop.

## Files touched

- `planck_agent/lib/planck/agent.ex` (pending map, GenServer API,
  resume/deny paths, expiry)
- `planck_agent/lib/planck/agent/turn.ex` (`:awaiting_approval` state)
- `planck_headless/lib/planck/headless.ex` (passthroughs, approval flag)
