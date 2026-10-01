# Step 3 — Preserve `disable-model-invocation` in the sidecar `write_skill` tool

Part of [v0.2.6-spec](../v0.2.6-spec.md). Depends on
[Step 1](step-1-frontmatter-field.md).

## Description

The sidecar's `write_skill` tool
(`planck_docker/sidecar/lib/sidecar/tools/write_skill.ex`) writes SKILL.md
files from agent-authored skill definitions. It already constructs the
frontmatter block from a fixed set of fields (lines 99-117) and preserves
`always_present` when present (lines 119-140).

Add the same preservation for `disable_model_invocation`: when the skill
definition passed to `write_skill` includes the field, emit it into the
written frontmatter; when absent, omit it (matching `always_present`'s
existing "only emit if set" behaviour).

This is the symmetric write-side counterpart to Step 1's read-side parser.
Without it, an agent-written skill that should be disabled-for-invocation
would lose the field on write, silently re-enabling model invocation the
next time the skill is loaded.

### TDD order

1. Write `write_skill_test.exs` cases asserting the field is emitted when
   set and omitted when absent (see Test Cases).
2. Run — they fail (the writer doesn't emit the field).
3. Add the emission logic, mirroring the `always_present` block.
4. Run — tests pass.

## Definition of Done

- [ ] `write_skill` emits `disable-model-invocation: true` (or `false`) into
      the SKILL.md frontmatter when the input skill definition includes the
      field.
- [ ] `write_skill` omits the line entirely when the input definition does
      not include `disable_model_invocation` (so a round-trip
      write → parse produces the same struct).
- [ ] The written frontmatter remains valid YAML parseable by Step 1's
      `parse_yaml_fields/2` — verified by a round-trip test (write, then
      parse with `Skill.from_file/1`, assert the field matches).
- [ ] Existing `write_skill` behaviour for `name`, `description`,
      `always_present`, `planck_version` is unchanged.
- [ ] `mix test` in the sidecar passes.
- [ ] `./check planck_docker/sidecar` passes (or the equivalent sidecar
      check command — confirm in `planck_docker/`).

## Use Cases

```gherkin
Feature: write_skill preserves disable-model-invocation

  Scenario: Writing a skill with disable_model_invocation: true
    Given a skill definition with
      | name                     | grill-me                        |
      | description              | Grills the user with questions. |
      | disable_model_invocation | true                            |
    When write_skill writes the SKILL.md
    Then the file's frontmatter contains the line
        "disable-model-invocation: true"
    And when Skill.from_file/1 re-parses the written file
    Then the resulting %Skill{} has disable_model_invocation == true

  Scenario: Writing a skill with disable_model_invocation: false
    Given a skill definition with
      | name                     | normal-skill                    |
      | description              | A self-loadable skill.           |
      | disable_model_invocation | false                           |
    When write_skill writes the SKILL.md
    Then the file's frontmatter contains the line
        "disable-model-invocation: false"
    And re-parsing yields disable_model_invocation == false

  Scenario: Writing a skill without the field omits the line
    Given a skill definition with only name and description
    When write_skill writes the SKILL.md
    Then the file's frontmatter does not contain "disable-model-invocation"
    And re-parsing yields disable_model_invocation == false

  Scenario: Round-trip preserves all existing fields
    Given a skill definition with name, description, always_present: true,
        planck_version: "0.2.6", and disable_model_invocation: true
    When write_skill writes and Skill.from_file/1 re-parses
    Then all six fields match the original definition
```

## Test Cases

In `planck_docker/sidecar/test/sidecar/tools/write_skill_test.exs` (or
wherever `write_skill` is tested — confirm the existing test file location):

- `describe "disable_model_invocation frontmatter"`:
  - emits `disable-model-invocation: true` when set true
  - emits `disable-model-invocation: false` when set false
  - omits the line when the field is absent from the input
  - round-trip: write a full definition (all six fields), re-parse with
    `Planck.Agent.Skill.from_file/1`, assert every field round-trips
  - regression: writing a definition without the new field produces a file
    identical to pre-feature output (diff against a fixture)

## Files touched

| File | Change |
|---|---|
| `planck_docker/sidecar/lib/sidecar/tools/write_skill.ex` | emit `disable-model-invocation` line when set (mirror `always_present` block, lines 119-140) |
| `planck_docker/sidecar/test/.../write_skill_test.exs` | new describe block + round-trip case |