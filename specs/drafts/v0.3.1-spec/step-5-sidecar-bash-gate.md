# Step 5 — Bundled `BashGate` + thresholds + session-start hold

Part of [v0.3.1-spec](../v0.3.1-spec.md). Depends on
[Steps 3–4](step-3-hook-behaviours.md). (Freeze the ETS record shape
here — Step 6 consumes it.)

## Description

Bundled sidecar modules (all hook *logic* lives sidecar-side):

- `Sidecar.Hooks.BashGate` (`use Planck.Agent.Hooks.ToolStart`):
  non-`bash` tools → `:ok` immediately (zero RLCD cost). For `bash`,
  evaluate the upstream `BASH_QUESTIONS` block verbatim (`effect`
  choice `{read_only, reversible, irreversible}` + `destructive_intent`
  boolean over `{command, cwd}`) and apply a two-tier rule: extreme
  band → `{:deny, reason + BLOCK_NOTICE}`; middle band →
  `{:await_approval, reason}`. No RLCD reachable → `:ok` (fail-open).
- `Sidecar.Hooks.ApprovalTagger` (`use Planck.Agent.Hooks.ToolEnd`):
  identity for everything except fresh gate-tagged blocked errors,
  which it decorates with the approval-widget `%{ui:}` (shape frozen
  here for Step 6) and writes the per-call ETS record keyed by
  `call_id` (`%{agent_id, tool, args_hash, command, reason,
  expires_at}`).
- `Sidecar.Config`: `BASH_GATE_IRREVERSIBLE_THRESHOLD` (0.6),
  `BASH_GATE_DESTRUCTIVE_THRESHOLD` (0.7) via Skogsra `app_env` +
  `os_env`; `compose.yml` `planck:` `environment:` gains both
  (`${VAR:-default}` pattern); `$PLANCK_HOME/.env` `add_if_missing`
  in `setup.sh`. Restart-required documented. RLCD calls go through
  the same credential-proxy path as headless (verify at build; the
  sidecar inherits container env — spawn is additive, no `:clear`).
- **Session-start hold** (`planck_headless`): sessions declaring
  `tool_start_hook` wait (bounded) for sidecar `:connected` before
  starting agents; on timeout, start anyway with fail-open + loud log.
  UI shows "waiting for sidecar" off the existing `planck:sidecar`
  topic.

### TDD order

1. Gate rule as pure function (verbatim upstream vectors).
2. Tier mapping + fail-open; tagger + ETS shape; config/env.
3. Session-start hold.

## Definition of Done

- Upstream `bash-gate.ts` vectors reproduced (read-only allows,
  destructive denies/awaits); `mix test` green in sidecar +
  headless hold tests.

## Use Cases

```gherkin
Feature: BashGate two-tier gating with env thresholds

  Scenario: Read-only command is allowed without friction
    Given command "ls -la src" in "/workspace"
    When the gate evaluates with effect read_only at high confidence
    Then it returns :ok and no RLCD-heavy path blocks the turn

  Scenario: Destructive command is parked for approval
    Given command "rm -rf _build" landing in the middle band
    When the gate evaluates
    Then it returns await_approval with a reason naming the destructive intent

  Scenario: Extreme irreversible command is denied outright
    Given command "git push --force origin main" with irreversible at high confidence
    When the gate evaluates
    Then it returns deny with the reason and the do-not-work-around notice

  Scenario: Non-bash tools bypass the gate
    Given a "write" call with the gate configured
    When the gate evaluates
    Then it returns :ok without any RLCD call

  Scenario: No RLCD fails open
    Given no RLCD model reachable
    When the gate evaluates any command
    Then it returns :ok and logs the fallback

  Scenario: Session waits for sidecar when a gate is declared
    Given a session with tool_start_hook declared and no sidecar yet
    When the session starts
    Then agents do not start until :connected or the hold timeout, which fails open loudly

  Scenario: Custom thresholds via env
    Given BASH_GATE_DESTRUCTIVE_THRESHOLD set in .env and a restart
    When the gate evaluates a borderline command
    Then the verdict follows the custom cutoff
```

## Test Cases

- Pure `gateBash` port incl. threshold boundaries; tier mapping;
  non-bash bypass (assert zero RLCD calls); fail-open paths;
  `Sidecar.Config` env parsing; ETS record shape; hold/wait/timeout.

## Files touched

- `planck_docker/sidecar/lib/sidecar/hooks/bash_gate.ex`,
  `approval_tagger.ex`, `approvals.ex` (ETS), `config.ex` (new)
- `planck_docker/sidecar/lib/sidecar/planck.ex` (no tool
  registration — hooks aren't tools; TEAM.json declares them)
- `planck_docker/compose.yml`, `planck_docker/planck/setup.sh`
- `planck_headless` session-start hold
