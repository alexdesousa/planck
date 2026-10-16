# Step 6 — `ApprovalModal` + auto-show on `:tool_blocked`

Part of [v0.3.1-spec](../v0.3.1-spec.md). Depends on
[Steps 4–5](step-4-approval-loop.md) (parked entries + Headless
passthroughs + gate reasons).

## Description

CLI-native approval UI (`planck_cli` only — no sidecar widget, no ETS;
parked approvals are owned by `Planck.Agent`, see Step 5):

- `Planck.Web.Live.ApprovalModal` (LiveComponent, `planck_cli`):
  lists parked tool calls awaiting human approval. Each entry shows
  the tool name, the gate's human-facing reason, and a fixed-height
  scrollable code block with the command/args (rendered via
  `ChatComponent.format_args/2`, highlighted by the shared
  `Hooks.Highlight` hook). Per-item Approve and Deny buttons forward
  to the parent LiveView via `send`; Deny carries an optional custom
  reason (empty means the default denial message).
- `SessionLive` wiring: a `:pending_approvals` assign, refreshed via
  `Headless.list_all_pending_approvals/1` whenever a `:tool_blocked`
  event with `mode: :await_approval` arrives and whenever the active
  session (re)loads (covers refresh-after-park). The modal renders
  whenever the list is non-empty and disappears when it drains.
  `approve_tool_call` / `deny_tool_call` events call the Headless
  passthroughs (Step 4) with the entry's owning `agent_id`, then
  re-fetch.
- Data shape per entry (from `list_all_pending_approvals/1`):
  `%{agent_id, call_id, tool_name, args, reason}` — flattened from the
  agent's parked `turn.running` entries, so the modal always reflects
  the live approval state with no second store to sync.

### Deliberately not built

- **No sidecar `ToolApproval` widget.** The earlier widget design
  (per-call ETS record, instance-keyed broadcasts, server-side binding
  validation, sidecar-down fallback) was superseded: with approvals
  owned agent-side and the modal fed by Headless reads, there is no
  sidecar state to render from and no binding to validate beyond the
  entry's own `agent_id` (one-shot consumption in `Planck.Agent`
  already rejects stale/double resolves with `:not_found`).
- **No auto-open/close widget protocol.** Show/hide derives directly
  from the `:pending_approvals` list — no `open_widget_id` handshake.

### TDD order

1. Modal render against stubbed approval entries (tool badge, reason,
   command block, per-item buttons).
2. Approve/deny event wiring (mock Headless passthroughs, re-fetch).
3. Auto-show on `:tool_blocked` + refresh reload + drain-to-close in
   LiveView tests.

## Definition of Done

- Approve resumes the exact parked call; deny ends it with the custom
  or default reason; stale/unknown `call_id` actions fail safely via
  the agent's one-shot consumption; modal tracks the live list
  (opens on park, closes on drain, survives refresh).

## Use Cases

```gherkin
Feature: Approval modal driven by Headless reads

  Scenario: Blocked command pops the modal automatically
    Given a parked bash call with a gate reason
    When the :tool_blocked event reaches the session view
    Then the approval modal opens showing the exact command and reason

  Scenario: Approve resumes the parked call
    Given the modal open for call C
    When the user clicks Approve
    Then the agent executes call C exactly once and the modal closes

  Scenario: Deny ends the call with a custom reason
    Given the modal open for call C
    When the user denies with reason "not now"
    Then the turn continues with a "not now" denial error and the modal closes

  Scenario: Stale action fails safely
    Given call C already resolved
    When an approve action for C arrives
    Then it fails without executing anything

  Scenario: Refresh preserves the modal
    Given a parked call and a reloaded session view
    When the view fetches pending approvals on load
    Then the modal reopens for the still-parked call
```

## Test Cases

- Render (badge, reason, command block, buttons); approve/deny event
  handling incl. empty-reason default; double-action safety;
  auto-show on `:tool_blocked`, re-fetch on session load,
  drain-to-close.

## Files touched

- `planck_cli/lib/planck/web/live/approval_modal.ex`,
  `approval_modal.html.heex` (new)
- `planck_cli/lib/planck/web/live/session_live.ex`,
  `session_live.html.heex` (pending list, event wiring)
- `planck_cli/assets/js/app.js` (shared `Highlight` hook)
