# Step 2 — Filter disabled skills out of the agent-facing pool

Part of [v0.3.0-spec](../v0.3.0-spec.md). Depends on
[Step 1](step-1-frontmatter-field.md).

## Description

At the three points in `planck_headless` where the agent-facing skill pool
is wired into a starting agent, reject skills with
`disable_model_invocation == true`. This removes them from both the
system-prompt index (so the model never sees them advertised) and the
`load_skill` tool's callable set (so the model can't load them by name on
its own).

The three wiring points, all in `planck_headless/lib/planck/headless.ex`:

1. **Primary/orchestrator** — `start_primary_agent` (lines 777-790): sets
   `skill_pool: store.skills` and
   `skill_refresh_fn: fn -> ResourceStore.get().skills end`.
2. **Static workers** — `start_workers` (lines 843-853): same pattern.
3. **Dynamically reconstructed workers** — `start_dynamic_worker` (lines
   1075-1085): same pattern.

Each gets the pool wrapped through `Enum.reject(& &1.disable_model_invocation)`
— for both the initial `skill_pool:` and the live `skill_refresh_fn:`
closure, so newly-added/reloaded disabled skills stay filtered on hot
reload (the watcher calls `ResourceStore.reload/0`, which re-reads the
skills; the refresh fn re-runs the reject on every `load_skill`/`list_skills`
call).

Disabled skills remain in `ResourceStore.skills` itself — that's the data
source the UI dropdown (Steps 5-7) and the slash-command backend (Step 4)
read from, so they stay user-reachable even while hidden from the model.

### TDD order

1. Write `headless_test.exs` cases asserting that an agent started with a
   pool containing one disabled skill does not receive that skill in its
   `load_skill` callable set or its system-prompt index (see Test Cases).
2. Run — they fail (no filtering applied).
3. Add the `Enum.reject` wrappers at all three wiring points.
4. Run — tests pass.

## Definition of Done

- [ ] All three wiring points in `headless.ex` (`start_primary_agent`,
      `start_workers`, `start_dynamic_worker`) wrap both `skill_pool:` and
      `skill_refresh_fn:` with
      `Enum.reject(& &1.disable_model_invocation)`.
- [ ] A disabled skill does not appear in an agent's system-prompt "Skills"
      or "Last used skills" sections.
- [ ] A disabled skill is not callable via the agent's `load_skill` tool —
      calling it returns the "Unknown skill" error listing only the
      non-disabled skills.
- [ ] `ResourceStore.get().skills` still contains disabled skills (the
      filter is applied at wiring time, not at load time).
- [ ] Hot reload preserves the filter: after `ResourceStore.reload/0`, a
      newly-disabled skill disappears from the agent's callable set on the
      next `load_skill`/`list_skills` invocation (the refresh fn re-runs
      the reject).
- [ ] `mix test` in `planck_headless` passes.
- [ ] `./check planck_headless` passes.

## Use Cases

```gherkin
Feature: Disabled skills are hidden from the model's autonomous set

  Background:
    Given ResourceStore is loaded with two skills:
      | name        | disable_model_invocation |
      | self-skill  | false                    |
      | gated-skill | true                     |
    And a session is started with a default orchestrator

  Scenario: Disabled skill is absent from the system-prompt index
    When the orchestrator builds its system prompt
    Then "self-skill" appears in the Skills or Last-used section
    And "gated-skill" does not appear anywhere in the system prompt

  Scenario: Disabled skill is not callable via load_skill
    When the orchestrator invokes load_skill with name "gated-skill"
    Then the result is {:error, "Unknown skill: gated-skill. Available: ..."}
    And the available list includes "self-skill"
    And the available list does not include "gated-skill"

  Scenario: Enabled skill is still callable via load_skill
    When the orchestrator invokes load_skill with name "self-skill"
    Then the result is {:ok, content} containing the skill's SKILL.md

  Scenario: ResourceStore still holds the disabled skill
    When ResourceStore.get().skills is read
    Then the list includes both "self-skill" and "gated-skill"
    # the UI and slash-command path read from here, not the filtered pool

  Scenario: Hot reload re-applies the filter
    Given an enabled skill "newly-gated" exists in the store
    And the agent's load_skill can currently load "newly-gated"
    When "newly-gated"'s SKILL.md is edited to set
        disable-model-invocation: true
    And the file watcher triggers ResourceStore.reload/0
    And the agent's load_skill refresh fn is called
    Then calling load_skill with name "newly-gated" returns
        {:error, "Unknown skill: newly-gated. ..."}

  Scenario: Static workers also receive the filtered pool
    Given a TEAM.json with one worker member
    When the team is started
    Then the worker's load_skill callable set excludes "gated-skill"
    And the worker's system-prompt index excludes "gated-skill"

  Scenario: Dynamically reconstructed workers receive the filtered pool
    Given a session that reconstructs a worker via start_dynamic_worker
    When the worker is started
    Then the worker's load_skill callable set excludes "gated-skill"
```

## Test Cases

In `planck_headless/test/planck/headless_test.exs` (or a new
`skill_filtering_test.exs` if that's the established pattern for
skill-pool tests — match the existing file organization):

- `describe "disabled skills are filtered from the agent pool"`:
  - start a session with a store containing one disabled + one enabled
    skill; assert the orchestrator's `load_skill` rejects the disabled
    name and accepts the enabled one.
  - assert `ResourceStore.get().skills` still contains the disabled skill
    (filter is at wiring, not at load).
  - assert a static worker started from the same store has the same
    filtering.
  - assert a dynamically reconstructed worker (`start_dynamic_worker`) has
    the same filtering.
- `describe "hot reload re-applies the filter"`:
  - start a session, edit a skill's SKILL.md to flip
    `disable-model-invocation` to `true`, call `ResourceStore.reload/0`,
  - assert the next `load_skill` refresh excludes the now-disabled skill.

These tests touch `ResourceStore` (global state), so they must use
`async: false` per the AGENTS.md convention.

## Open question

See [v0.3.0-spec.md](../v0.3.0-spec.md) Open Question 2: whether
`spawn_agent`'s `filter_granted` should also hide disabled skills. This
step's Definition of Done does **not** change the `spawn_agent` path —
confirm during implementation whether that's the desired behaviour; if so,
extend the filter in `planck_agent/lib/planck/agent/tools.ex:283` too and
add a corresponding test case here.

## Files touched

| File | Change |
|---|---|
| `planck_headless/lib/planck/headless.ex` | wrap `skill_pool:` + `skill_refresh_fn:` at lines ~777-790, ~843-853, ~1075-1085 |
| `planck_headless/test/planck/headless_test.exs` (or new file) | filtering + hot-reload test cases |