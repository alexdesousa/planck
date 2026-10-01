# Step 5 — Pass the full skill list from `ResourceStore` to `PromptInput`

Part of [v0.2.6-spec](../v0.2.6-spec.md). Depends on
[Step 1](step-1-frontmatter-field.md) (for the `disable_model_invocation`
flag the dropdown needs to mark disabled skills).

## Description

Make the full, unfiltered skill list — including
`disable_model_invocation: true` skills — available to the `PromptInput`
LiveComponent so the dropdown in [Step 6](step-6-ui-dropdown.md) can
render and mark every skill.

`ResourceStore.get().skills` already holds the full list (Step 2 filters
only at the agent-pool wiring points, not at load time). The parent
LiveView (`session_live.ex`) already reads from `ResourceStore` at mount
(e.g. line 49 reads `.teams`). This step adds `.skills` to the same
read and passes it down to `PromptInput` as an assign.

The skill list should be a lightweight projection — just the fields the
dropdown needs (`name`, `description`, `disable_model_invocation`) — to
avoid pushing the full `Skill.t` struct (with file paths) to the UI. A
small map or a trimmed struct is fine; match whatever shape the existing
`PromptInput` assigns use.

### TDD order

1. Write a `prompt_input_test.exs` case asserting the component receives a
   `skills` assign with the expected shape when rendered by the parent
   LiveView.
2. Run — it fails (no `skills` assign exists).
3. Add the `ResourceStore.get().skills` read + assign pass-through.
4. Run — test passes.

## Definition of Done

- [ ] `session_live.ex` reads `ResourceStore.get().skills` (alongside the
      existing `.teams` read) and passes a trimmed projection to
      `PromptInput` as a `skills` assign.
- [ ] The `skills` assign contains every skill in the store, including
      disabled-invocation ones (the dropdown needs the full set).
- [ ] Each entry in the `skills` assign includes at least `name`,
      `description`, and `disable_model_invocation`.
- [ ] `PromptInput` accepts and stores the `skills` assign in its
      `update/2` callback (`prompt_input.ex:16`).
- [ ] Hot reload: when `ResourceStore.reload/0` runs (file watcher), the
      parent LiveView re-reads `.skills` and pushes the updated list to
      `PromptInput`. (Confirm whether `session_live` already re-reads
      `ResourceStore` on reload events; if not, add a handler.)
- [ ] No behavioural change yet — the dropdown rendering is Step 6. This
      step only wires the data.
- [ ] `mix test` in `planck_cli` passes.
- [ ] `./check planck_cli` passes.

## Use Cases

```gherkin
Feature: PromptInput receives the full skill list

  Background:
    Given ResourceStore is loaded with skills:
      | name        | description              | disable_model_invocation |
      | self-skill  | A self-loadable skill.    | false                    |
      | gated-skill | A gated skill.           | true                     |

  Scenario: PromptInput receives both skills as an assign
    When the session LiveView mounts
    And renders the PromptInput component
    Then the PromptInput's assigns include a "skills" list
    And the list contains an entry for "self-skill"
    And the list contains an entry for "gated-skill"
    And each entry has name, description, and disable_model_invocation fields

  Scenario: Disabled-invocation flag is carried through
    When the PromptInput receives the skills assign
    Then the "gated-skill" entry has disable_model_invocation == true
    And the "self-skill" entry has disable_model_invocation == false

  Scenario: Skill list updates on hot reload
    Given the session is mounted with the initial skill list
    When a new skill "fresh-skill" is added to the skills directory
    And the file watcher triggers ResourceStore.reload/0
    Then the PromptInput's skills assign includes "fresh-skill"

  Scenario: No rendering change yet
    When the PromptInput renders with the skills assign
    Then the rendered HTML is identical to before this step
    # the dropdown is added in Step 6, not here
```

## Test Cases

In `planck_cli/test/planck/web/live/prompt_input_test.exs` (or
`session_live_test.exs`, matching existing test organization):

- `describe "skills assign"`:
  - rendering `PromptInput` via the parent LiveView with a ResourceStore
    containing two skills (one disabled) produces a `skills` assign with
    both entries, each carrying `name`, `description`,
    `disable_model_invocation`.
  - the disabled skill's `disable_model_invocation` is `true` in the
    assign.
- `describe "hot reload updates the skill list"`:
  - after `ResourceStore.reload/0` with a newly-added skill, the
    `PromptInput` `skills` assign includes the new skill.

These tests touch `ResourceStore` (global state) → `async: false`.

## Files touched

| File | Change |
|---|---|
| `planck_cli/lib/planck/web/live/session_live.ex` | read `ResourceStore.get().skills`, pass trimmed projection to `PromptInput` |
| `planck_cli/lib/planck/web/live/prompt_input.ex` | accept + store `skills` in `update/2` |
| `planck_cli/lib/planck/web/live/session_live.html.heex` | pass `skills={...}` to the `.live_component` (line 50-55) |
| `planck_cli/test/.../prompt_input_test.exs` (or `session_live_test.exs`) | skills-assign + hot-reload cases |