# Step 6 — Render + filter the autocomplete dropdown on `/` prefix

Part of [v0.2.6-spec](../v0.2.6-spec.md). Depends on
[Step 5](step-5-ui-skill-list.md) (for the `skills` assign).

## Description

When the `PromptInput` textarea text starts with `/`, render a floating
autocomplete panel listing skills whose `name` matches the typed prefix.
The panel:

- Opens when the first character of the current text is `/`.
- Filters skills by prefix match on `name` as the user types more (e.g.
  `/gri` matches `grill-me`, `grind-it`, etc.). Case-insensitive.
- Shows the skill `name` and `description` for each match.
- Visually marks `disable_model_invocation: true` skills (e.g. a small
  "manual" badge or dimmed styling) so the user can tell which ones the
  model can't self-load.
- Closes when the text no longer starts with `/`, when no skills match,
  or when selection happens (Step 7) / Escape is pressed (Step 7).

Filtering happens in `PromptInput.handle_event("change", ...)` (currently
at `prompt_input.ex:36`, which only syncs `:text` — extend it to also
compute a `:skill_matches` list and a `:dropdown_open` flag). The dropdown
markup goes in `prompt_input.html.heex`, rendered conditionally on
`:dropdown_open`.

### Positioning

The existing `FloatingDropdown` JS hook (`app.js:83-101`) repositions a
panel *below* its trigger via `getBoundingClientRect()`. A skill dropdown
anchored to a textarea at the bottom of the chat likely needs to open
*above* the textarea (otherwise it renders off-screen below). Resolve
[v0.2.6-spec.md](../v0.2.6-spec.md) Open Question 3 during this step:

- Add a `position: :above` option to `FloatingDropdown`, or
- Write a dedicated `SkillDropdown` hook that positions above.

Either is acceptable; a dedicated hook keeps the dropdown's
textarea-anchored concerns separate from the existing
button-anchored `FloatingDropdown`.

### TDD order

1. Write `prompt_input_test.exs` cases asserting the dropdown renders
   with matches when text starts with `/`, filters by prefix, and closes
   when the prefix doesn't match (see Test Cases).
2. Run — they fail (no dropdown markup / no filtering logic).
3. Add the `change` handler filtering + the conditional dropdown markup.
4. Run — tests pass.

## Definition of Done

- [ ] `PromptInput.handle_event("change", ...)` detects a leading `/`,
      extracts the partial skill name, and computes a filtered
      `:skill_matches` list from the `:skills` assign (case-insensitive
      prefix match on `name`).
- [ ] When text doesn't start with `/`, or no skills match the prefix,
      `:dropdown_open` is `false` and no panel renders.
- [ ] The dropdown panel renders in `prompt_input.html.heex` when
      `:dropdown_open`, listing each match's `name` + `description`.
- [ ] `disable_model_invocation: true` matches are visually marked
      (badge/dimmed) — the exact styling matches the NeoBrutalism design
      system already used in `components.ex`.
- [ ] The panel is positioned *above* the textarea (resolved Open
      Question 3) and stays positioned on scroll/resize (reuse the
      `getBoundingClientRect` repositioning pattern from
      `FloatingDropdown`, or a new hook).
- [ ] Typing `/` alone (no further chars) lists every skill in the store
      (all are prefix matches of the empty prefix).
- [ ] `mix test` in `planck_cli` passes.
- [ ] `./check planck_cli` passes.

## Use Cases

```gherkin
Feature: Skill autocomplete dropdown on / prefix

  Background:
    Given the PromptInput has a skills assign with:
      | name        | description              | disable_model_invocation |
      | grill-me    | Grills with questions.    | true                     |
      | grind-it    | Grinds through tasks.     | false                    |
      | brew-coffee | Brews coffee.             | false                    |
    And the textarea is empty

  Scenario: Typing / opens the dropdown with all skills
    When the user types "/"
    Then the dropdown panel is visible
    And the panel lists grill-me, grind-it, and brew-coffee
    And grill-me is visually marked as manual (disabled invocation)

  Scenario: Typing a prefix filters matches
    When the user types "/gri"
    Then the dropdown panel is visible
    And the panel lists grill-me and grind-it
    And brew-coffee is not listed

  Scenario: Prefix match is case-insensitive
    When the user types "/GRI"
    Then the panel lists grill-me and grind-it

  Scenario: No matches closes the dropdown
    When the user types "/xyz"
    Then the dropdown panel is not visible

  Scenario: Removing the leading slash closes the dropdown
    Given the user has typed "/gri" and the dropdown is open
    When the user edits the text to "hello"
    Then the dropdown panel is not visible

  Scenario: Disabled-invocation skills appear with a mark
    When the user types "/"
    Then grill-me appears with a "manual" badge or dimmed styling
    And grind-it and brew-coffee appear without the mark

  Scenario: Dropdown is positioned above the textarea
    When the dropdown opens
    Then the panel's bottom edge is at or above the textarea's top edge
    And the panel remains correctly positioned on window scroll/resize
```

## Test Cases

In `planck_cli/test/planck/web/live/prompt_input_test.exs`:

- `describe "slash autocomplete dropdown"`:
  - typing `/` renders the dropdown with all skills
  - typing `/gri` filters to grill-me + grind-it
  - typing `/GRI` is case-insensitive
  - typing `/xyz` renders no dropdown (no matches)
  - editing `/gri` to `hello` closes the dropdown
  - disabled-invocation skill is rendered with a marking (assert the
    marking element/ class is present)
  - dropdown markup is absent when text doesn't start with `/` (regression
    guard: non-slash input is unaffected)

- `describe "dropdown positioning"`:
  - the rendered panel has positioning attributes / hook indicating
    above-textarea placement (assert the hook is attached or the
    positioning class is present; full pixel-level positioning is a JS
    concern, lightly asserted here)

## Files touched

| File | Change |
|---|---|
| `planck_cli/lib/planck/web/live/prompt_input.ex` | extend `change` handler: detect `/`, filter matches, set `:dropdown_open`/`:skill_matches` |
| `planck_cli/lib/planck/web/live/prompt_input.html.heex` | conditional dropdown panel markup with match entries + disabled marking |
| `planck_cli/assets/js/app.js` | (possibly) new `SkillDropdown` hook or `position: :above` option on `FloatingDropdown` |
| `planck_cli/test/planck/web/live/prompt_input_test.exs` | dropdown render + filter + close cases |