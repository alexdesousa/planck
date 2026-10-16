# Step 5 — Bundled `BashGate` + thresholds

Part of [v0.3.1-spec](../v0.3.1-spec.md). Depends on
[Steps 3–4](step-3-hook-behaviours.md).

## Description

Bundled sidecar modules (all hook *logic* lives sidecar-side):

- `Sidecar.Hooks.BashGate` (`use Planck.Agent.Hooks.ToolStart`):
  non-`bash` tools → `:ok` immediately (zero RLCD cost). For `bash`,
  evaluate the upstream `BASH_QUESTIONS` block verbatim (`effect`
  choice `{read_only, reversible, irreversible}` + `destructive_intent`
  boolean over `{command, cwd}`) via `Planck.Headless.ask/2` (the
  sidecar holds no model credentials — same rule as the agent tools
  `ask`/`ask_files`, which resolve their model from the store). Any
  blocked signal (irreversible at/above threshold or destructive
  intent at/above threshold) → `{:await_approval, reason}`. Model
  verdicts never deny; only the human denies, in the approval modal.
  Transport failures (no headless node, RPC failure, exceptions) deny
  loudly instead. Reasons
  are human-facing and translated sidecar-side (`Sidecar.Gettext`,
  locale pushed per request) — what the gate returns is what the modal
  shows. No RLCD model configured (`:no_rlcd_model`, i.e. no gate
  configured) → `:ok`. Any other evaluation failure (no headless node,
  RPC failure, raised exception) → `{:deny, reason}` loudly, so `bash`
  never runs unevaluated when a gate is configured. This deliberately
  diverges from the `ToolStart` RPC wrapper's fail-open rule: a gate
  transport failure is itself a safety signal.
- `Sidecar.Config`: `BASH_GATE_IRREVERSIBLE_THRESHOLD` (0.6),
  `BASH_GATE_DESTRUCTIVE_THRESHOLD` (0.7) via Skogsra `app_env` +
  `os_env`; `compose.yml` `planck:` `environment:` gains both
  (`${VAR:-default}` pattern, Skogsra defaults cover existing
  installs — no `setup.sh` migration needed). Restart-required
  documented. RLCD calls go through
  the same credential-proxy path as headless (verify at build; the
  sidecar inherits container env — spawn is additive, no `:clear`).

### Deliberately not built

- **No `ApprovalTagger` (`ToolEnd`).** Gates return 2-tuples only
  (Step 3 contract) — UI side effects are not attached hook-side. The
  approval UI is `planck_cli`'s `ApprovalModal`, fed by `:tool_blocked`
  events plus `list_all_pending_approvals/1` on refresh. Nothing needs
  tagging.
- **No sidecar ETS approvals store.** Parked approvals are owned by
  `Planck.Agent` (`turn.running` parked entries), surfaced via
  `Agent.list_pending_approvals/0` and the Headless passthroughs. A
  sidecar-side copy would be a second source of truth to keep in sync
  for no consumer.
- **No session-start hold.** `ToolStart` dispatch already fails open on
  `:badrpc`/missing sidecar (Step 3), and the gate itself denies loudly
  when headless is unreachable — the ungated window self-resolves when
  the sidecar connects. No startup coordination in `planck_headless`.

### TDD order

1. Gate rule as pure function (verbatim upstream vectors).
2. Park mapping + fail-closed transport errors; config/env.

## Definition of Done

- Upstream `bash-gate.ts` vectors reproduced (read-only allows,
  destructive parks); `mix test` green in sidecar.

## Use Cases

```gherkin
Feature: BashGate park-only gating with env thresholds

  Scenario: Read-only command is allowed without friction
    Given command "ls -la src" in "/workspace"
    When the gate evaluates with effect read_only at high confidence
    Then it returns :ok and no RLCD-heavy path blocks the turn

  Scenario: Destructive command is parked for approval
    Given command "rm -rf _build" with destructive intent above threshold
    When the gate evaluates
    Then it returns await_approval with a human-facing, translated reason naming the destructive intent

  Scenario: Extreme irreversible command is parked, never denied on its verdict
    Given command "git push --force origin main" with irreversible at high confidence
    When the gate evaluates
    Then it returns await_approval; only the human denies, in the modal

  Scenario: Non-bash tools bypass the gate
    Given a "write" call with the gate configured
    When the gate evaluates
    Then it returns :ok without any RLCD call

  Scenario: No RLCD model configured bypasses the gate
    Given no RLCD model available
    When the gate evaluates any command
    Then it returns :ok and logs that no gate is configured

  Scenario: Unreachable evaluation path denies loudly
    Given no headless node, an RPC failure, or a raised exception
    When the gate evaluates any bash command
    Then it returns deny with a warning, never running bash unevaluated

  Scenario: Custom thresholds via env
    Given BASH_GATE_DESTRUCTIVE_THRESHOLD set in .env and a restart
    When the gate evaluates a borderline command
    Then the verdict follows the custom cutoff
```

## Test Cases

- Pure `gateBash` port incl. threshold boundaries; park mapping;
  non-bash bypass (assert zero RLCD calls); fail-closed transport-error
  paths; `Sidecar.Config` env parsing.

## Files touched

- `planck_docker/sidecar/lib/sidecar/hooks/bash_gate.ex`,
  `config.ex`
- `planck_docker/sidecar/lib/sidecar/planck.ex` (no tool
  registration — hooks aren't tools; TEAM.json declares them)
- `planck_docker/compose.yml`
