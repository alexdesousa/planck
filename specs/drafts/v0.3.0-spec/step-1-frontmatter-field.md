# Step 1 — Frontmatter field `disable-model-invocation`

Part of [v0.3.0-spec](../v0.3.0-spec.md).

## Description

Add a `disable_model_invocation` boolean field to `Planck.Agent.Skill.t()`
and parse it from SKILL.md frontmatter. When `true`, the skill is a
candidate for exclusion from the agent's autonomous skill set (filtered in
[Step 2](step-2-pool-filtering.md)); when absent or `false`, behaviour is
unchanged from today.

The field lives in the frontmatter alongside the existing five keys
(`name`, `description`, `always_present`, `planck_version`, `creator`) and
follows the same parse path: `parse_frontmatter/2` →
`parse_yaml_fields/2` → `yaml_field/2` in
`planck_agent/lib/planck/agent/skill.ex`.

This step is purely a data-model + parser change — no filtering, no
behavioural effect yet. That keeps it independently testable and lets
[Step 2](step-2-pool-filtering.md) depend on a stable struct field rather
than a parser detail.

### TDD order

1. Write `skill_test.exs` cases asserting the struct field defaults to
   `false` and parses `true`/`false`/absent correctly (see Test Cases).
2. Run — they fail (`disable_model_invocation` doesn't exist on the struct,
   and the parser doesn't extract it).
3. Add the field to `Skill.t` and the struct default.
4. Extract the field in `parse_yaml_fields/2`.
5. Run — tests pass.

## Definition of Done

- [ ] `Skill.t()` has a `disable_model_invocation: boolean()` field,
      default `false` in `defstruct`.
- [ ] `parse_yaml_fields/2` (`skill.ex:341`) extracts
      `disable_model_invocation` via `yaml_field/2` and includes it in the
      returned map, normalized to a boolean (`true` only when the YAML
      value is literally `true`; anything else, including absence,
      normalizes to `false`).
- [ ] `Skill.from_file/1` round-trips the field: a SKILL.md with
      `disable-model-invocation: true` produces a `%Skill{}` with the
      field set; a SKILL.md without the key produces `%Skill{
      disable_model_invocation: false}`.
- [ ] Existing frontmatter keys and their parsing are unchanged — the
      `skill_test.exs` cases for `name`, `description`, `always_present`,
      `planck_version`, `creator` still pass without modification.
- [ ] The module docstring at `skill.ex:40-41` (currently stale — it claims
      only `name` and `description` are parsed) is updated to list all six
      fields, including `disable_model_invocation`.
- [ ] `mix test` in `planck_agent` passes.
- [ ] `./check planck_agent` passes.

## Use Cases

```gherkin
Feature: disable-model-invocation frontmatter field

  Background:
    Given a temporary skills directory with a SKILL.md containing valid
    frontmatter

  Scenario: Parsing a skill with disable-model-invocation: true
    Given the SKILL.md frontmatter is
      """
      ---
      name: grill-me
      description: Grills the user with hard questions.
      disable-model-invocation: true
      ---
      """
    When Skill.from_file/1 parses the file
    Then the returned %Skill{} has disable_model_invocation == true
    And the name is "grill-me"
    And the description is "Grills the user with hard questions."
    And always_present == false

  Scenario: Parsing a skill with disable-model-invocation: false
    Given the SKILL.md frontmatter is
      """
      ---
      name: safe-skill
      description: A normal self-loadable skill.
      disable-model-invocation: false
      ---
      """
    When Skill.from_file/1 parses the file
    Then the returned %Skill{} has disable_model_invocation == false

  Scenario: Parsing a skill without the disable-model-invocation key
    Given the SKILL.md frontmatter is
      """
      ---
      name: legacy-skill
      description: A skill that predates this field.
      ---
      """
    When Skill.from_file/1 parses the file
    Then the returned %Skill{} has disable_model_invocation == false
    And the struct is otherwise identical to one parsed before this feature
    existed

  Scenario: Parsing a skill with a non-boolean disable-model-invocation value
    Given the SKILL.md frontmatter is
      """
      ---
      name: bad-skill
      description: Has a malformed value.
      disable-model-invocation: "yes"
      ---
      """
    When Skill.from_file/1 parses the file
    Then the returned %Skill{} has disable_model_invocation == false
    # non-true values normalize to false, matching always_present's
    # existing `always_present == true` normalization at skill.ex:364

  Scenario: Default struct field
    When a %Skill{} is constructed with only name and description
    Then disable_model_invocation == false

  Scenario: Existing skills without the field still load via load_all/1
    Given the bundled skills/planck_setup/SKILL.md which has no
      disable-model-invocation key
    When Skill.load_all/1 loads it
    Then the returned skill has disable_model_invocation == false
    And always_present == true
    And planck_version is unchanged
```

## Test Cases

In `planck_agent/test/planck/agent/skill_test.exs`:

- `describe "disable_model_invocation frontmatter"`:
  - parses `true` from frontmatter → `disable_model_invocation == true`
  - parses `false` from frontmatter → `disable_model_invocation == false`
  - absent key → `disable_model_invocation == false`
  - non-boolean value (`"yes"`) → `disable_model_invocation == false`
- `describe "Skill struct defaults"`:
  - new `%Skill{name: ..., description: ...}` has
    `disable_model_invocation == false`
- Extend the existing `load_all` / `from_file` describe block:
  - the bundled `planck_setup` skill loads with
    `disable_model_invocation == false` and existing fields unchanged
    (regression guard).

## Files touched

| File | Change |
|---|---|
| `planck_agent/lib/planck/agent/skill.ex` | add field to `t()` + `defstruct`; extract in `parse_yaml_fields/2`; update docstring |
| `planck_agent/test/planck/agent/skill_test.exs` | new + extended describe blocks |