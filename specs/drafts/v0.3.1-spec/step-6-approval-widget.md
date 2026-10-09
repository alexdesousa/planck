# Step 6 — `ToolApproval` sidecar widget + auto-open

Part of [v0.3.1-spec](../v0.3.1-spec.md). Depends on
[Step 5](step-5-sidecar-bash-gate.md) (ETS record shape).

## Description

- `Sidecar.Widgets.ToolApproval` (`use Planck.Agent.Widget`,
  `id: "tool_approval"`, default `:modal` container): first paint
  from the `data` snapshot (`%{call_id, agent_id, tool, command,
  reason}`); refreshes from the Step-5 ETS record; broadcasts on
  `sidecar:widget:<instance>` per call (instance keyed by `call_id`,
  Beads precedent). `handle_action("approve"/"deny", %{"call_id",
  "agent_id"})` validates the binding server-side, then
  `:rpc.call(PLANCK_HEADLESS_NODE, Planck.Agent, :approve_tool_call |
  :deny_tool_call, ...)` to resume.
- Core (`planck_cli`, ~10 lines + template): `SessionLive` observes
  `:tool_blocked` and sets `open_widget_id` proactively (widgets
  otherwise open on click, but a parked agent is waiting); modal
  closes on the tool's completion event or a resolution broadcast.
- Sidecar-down-after-tagging hits the existing
  `:sidecar_not_connected` fallback; expiry auto-deny is the backstop.

### TDD order

1. Widget render/action against a stubbed ETS record.
2. Approve/deny resume wiring (mock headless RPC).
3. Auto-open on `:tool_blocked` + close paths.

## Definition of Done

- Click-approve resumes the exact parked call; click-deny ends it;
  stale/unknown `call_id` actions fail safely; sidecar-down renders
  the fallback.

## Use Cases

```gherkin
Feature: Approval modal driven by the sidecar widget

  Scenario: Blocked command pops the modal automatically
    Given a parked bash call with an approval tag
    When the :tool_blocked event reaches the session view
    Then the approval modal opens showing the exact command and reason

  Scenario: Approve resumes the parked call
    Given the modal open for call C
    When the user clicks Approve
    Then the agent executes call C exactly once and the modal closes

  Scenario: Deny ends the call
    Given the modal open for call C
    When the user clicks Deny
    Then the turn continues with a denial error and the modal closes

  Scenario: Stale action fails safely
    Given call C already resolved
    When an approve action for C arrives
    Then it fails without executing anything

  Scenario: Sidecar disconnect degrades gracefully
    Given a tagged approval whose sidecar is now down
    When the modal renders
    Then it shows the not-connected fallback and expiry auto-denies in time
```

## Test Cases

- Render from snapshot vs ETS refresh; instance-keyed broadcasts;
  action validation incl. binding mismatch; double-action safety;
  auto-open/close event handling in LiveView tests.

## Files touched

- `planck_docker/sidecar/lib/sidecar/widgets/tool_approval.ex` (new)
- `planck_cli/lib/planck/web/live/session_live.ex`,
  `chat_component.ex` (auto-open wiring)
