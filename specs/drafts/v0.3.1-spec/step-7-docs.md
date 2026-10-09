# Step 7 — Docs, CHANGELOG, version bump

Part of [v0.3.1-spec](../v0.3.1-spec.md). Depends on Steps 1–6.

## Description

- `skills/planck_setup/references/teams.md`: `ask`/`ask_files`
  schemas, RLCD gating, `boolean` ≡ `noul`, gating recipe
  (`ask_files` → act where `noul > Y`, re-`read` hits only).
- `skills/planck_setup/references/hooks.md`: the three new
  behaviours, sync/async split, TEAM.json fields, fail-open table,
  approval-loop overview pointing at the widget.
- `skills/planck_setup/references/tool-shadowing.md`: composed-reader
  note (`ask_files` resolves live `read`), approval UI kind note.
- `specs/sidecar.md`, `specs/widgets.md` as needed; CHANGELOG entries
  incl. `classify` removal + restart-required thresholds.
- Version bump lockstep: all four Mix packages +
  `planck_docker/sidecar/mix.exs` (per AGENTS.md).

## Definition of Done

- Every new tool/hook/field documented where its siblings are;
  `./check` green.

## Use Cases

```gherkin
Feature: Docs match the shipped behavior

  Scenario: Setup skill answers RLCD questions
    Given the planck-setup skill index
    When an agent asks how to gate on file triage or block bash
    Then teams.md and hooks.md contain the ask/ask_files schemas and the gate recipe

  Scenario: Changelog records breaking changes
    Given the v0.3.1 CHANGELOG entries
    When a user upgrades from v0.3.0
    Then the classify removal and threshold restart requirement are both stated
```

## Test Cases

- Doc-code consistency pass (names, fields, defaults match
  implementation); `./check` full-repo green.

## Files touched

- `skills/planck_setup/references/*`, `specs/*.md` as needed,
  `CHANGELOG.md` files, `VERSION`, five `mix.exs` files
