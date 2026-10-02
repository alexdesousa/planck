# Step 6 — Render + filter the command autocomplete dropdown on `/` prefix

Part of [v0.3.0-spec](../v0.3.0-spec.md). Depends on
[Step 5](step-5-ui-skill-list.md) (for the `commands` assign).

## Description

When the `PromptInput` textarea text starts with `/`, render a floating
autocomplete panel listing commands whose `name` matches the typed prefix.
The panel covers all three tiers from [Step 4](step-4-slash-command-backend.md)
— built-in primitives, custom commands, and skills — in a single filtered
list.

The panel:

- Opens when the first character of the current text is `/`.
- Filters commands by case-insensitive prefix match on `name` as the user
  types more (e.g. `/gri` matches `grill-me`, `grind-it`, etc.).
- Shows each match's `name` (primary) and `help` text as the subtitle
  (secondary line). For entries without a `help` field (skills, and any
  command without one), the `description` is shown as the subtitle
  instead.
- Renders a **type badge** on each row distinguishing the tier:
  - `:builtin` → a "builtin" badge (e.g. a small system-colored tag)
  - `:command` → a "command" badge
  - `:skill` → no type badge, but disabled-invocation skills keep the
    existing "manual" badge from the v0.2.6 design
- Preserves the tier ordering from [Step 5]'s `commands` assign
  (builtins → commands → skills, alphabetical within each tier) in the
  filtered results — the filter removes non-matches but does not re-sort.
- Closes when the text no longer starts with `/`, when no commands match,
  or when selection happens ([Step 7](step-7-ui-keyboard-mouse.md)) /
  Escape is pressed ([Step 7]).

Filtering happens in `PromptInput.handle_event("change", ...)` (currently
at `prompt_input.ex:36`, which only syncs `:text` — extend it to also
compute a `:command_matches` list and a `:dropdown_open` flag). The
dropdown markup goes in `prompt_input.html.heex`, rendered conditionally
on `:dropdown_open`.

### Positioning

The existing `FloatingDropdown` JS hook (`app.js:83-101`) repositions a
panel *below* its trigger via `getBoundingClientRect()`. A command
dropdown anchored to a textarea at the bottom of the chat needs to open
*above* the textarea (otherwise it renders off-screen below). Resolve
[v0.3.0-spec.md](../v0.3.0-spec.md) Open Question 3 during this step:

- Add a `position: :above` option to `FloatingDropdown`, or
- Write a dedicated `CommandDropdown` hook that positions above.

Either is acceptable; a dedicated hook keeps the dropdown's
textarea-anchored concerns separate from the existing button-anchored
`FloatingDropdown`.

### Row rendering detail

Each dropdown row renders (top to bottom):

1. **Name** — the command name (e.g. `review-checklist`), bold.
2. **Subtitle** — `help` if present, else `description`. For built-ins,
   `help` is always present (`/clear`, `/compact [prompt]`). For custom
   commands, `help` may be present. For skills, `help` is `nil`, so
   `description` is used.
3. **Badges** (right-aligned or trailing the name):
   - Type badge: "builtin" for `:builtin`, "command" for `:command`.
     `:skill` rows have no type badge.
   - "manual" badge: shown only on skills with
     `disable_model_invocation: true` (carried over from the v0.2.6
     design). Built-ins and custom commands do not get this badge (their
     `disable_model_invocation` is always `true` and not meaningful to
     surface — it only gates the follow-up `run_command` tool, not user
     invocation).

### TDD order

1. Write `prompt_input_test.exs` cases asserting the dropdown renders
   with matches when text starts with `/`, filters by prefix across all
   three tiers, preserves tier ordering, and closes when the prefix
   doesn't match (see Test Cases).
2. Run — they fail (no dropdown markup / no filtering logic).
3. Add the `change` handler filtering + the conditional dropdown markup
   with row rendering (name + subtitle + badges).
4. Run — tests pass.

## Definition of Done

- [ ] `PromptInput.handle_event("change", ...)` detects a leading `/`,
      extracts the partial command name, and computes a filtered
      `:command_matches` list from the `:commands` assign
      (case-insensitive prefix match on `name`).
- [ ] The filter covers all three kinds (`:builtin`, `:command`, `:skill`)
      in a single pass — there is no per-tier filtering logic.
- [ ] When text doesn't start with `/`, or no commands match the prefix,
      `:dropdown_open` is `false` and no panel renders.
- [ ] The dropdown panel renders in `prompt_input.html.heex` when
      `:dropdown_open`, listing each match with `name` + subtitle.
- [ ] Each row's subtitle is the `help` field when present, else the
      `description`.
- [ ] `:builtin` rows show a "builtin" type badge; `:command` rows show a
      "command" type badge; `:skill` rows show no type badge.
- [ ] `:skill` rows with `disable_model_invocation: true` show a "manual"
      badge (carried over from v0.2.6). Other kinds do not show this
      badge.
- [ ] The filtered list preserves the tier ordering from the `commands`
      assign (builtins → commands → skills, alphabetical within each
      tier) — the filter removes non-matches but does not re-sort.
- [ ] Typing `/` alone (no further chars) lists every command in the
      store (all are prefix matches of the empty prefix), in tier order.
- [ ] The panel is positioned *above* the textarea (resolved Open
      Question 3) and stays positioned on scroll/resize (reuse the
      `getBoundingClientRect` repositioning pattern from
      `FloatingDropdown`, or a new hook).
- [ ] The exact badge/styling matches the NeoBrutalism design system
      already used in `components.ex`.
- [ ] `mix test` in `planck_cli` passes.
- [ ] `./check planck_cli` passes.

## Use Cases

```gherkin
Feature: Command autocomplete dropdown on / prefix

  Background:
    Given the PromptInput has a commands assign with:
      | name             | kind    | description              | disable_model_invocation | help                |
      | clear            | builtin | Delete all messages.      | true                     | "/clear"            |
      | compact          | builtin | Compact the session.      | true                     | "/compact [prompt]" |
      | review-checklist | command | Runs the review checklist. | true                     | "/review-checklist" |
      | grill-me         | skill   | Grills with questions.    | true                     | nil                 |
      | grind-it         | skill   | Grinds through tasks.     | false                    | nil                 |
      | brew-coffee      | skill   | Brews coffee.             | false                    | nil                 |
    And the textarea is empty

  Scenario: Typing / opens the dropdown with all commands in tier order
    When the user types "/"
    Then the dropdown panel is visible
    And the panel lists, in order: clear, compact, review-checklist, grill-me, grind-it, brew-coffee
    And clear and compact show "builtin" type badges
    And review-checklist shows a "command" type badge
    And grill-me, grind-it, brew-coffee show no type badge
    And grill-me shows a "manual" badge (disabled invocation)
    And grind-it and brew-coffee do not show a "manual" badge

  Scenario: Typing a prefix filters across all tiers
    When the user types "/gri"
    Then the dropdown panel is visible
    And the panel lists grill-me and grind-it
    # both are skills; no builtins or commands match "gri"
    And clear, compact, review-checklist, brew-coffee are not listed

  Scenario: Prefix match is case-insensitive
    When the user types "/GRI"
    Then the panel lists grill-me and grind-it

  Scenario: Prefix matches a built-in
    When the user types "/c"
    Then the panel lists clear and compact
    # both builtins start with "c"; no commands or skills match

  Scenario: Prefix matches across tiers
    When the user types "/co"
    Then the panel lists compact (builtin) and brew-coffee (skill)
    And compact appears before brew-coffee (tier order preserved)

  Scenario: No matches closes the dropdown
    When the user types "/xyz"
    Then the dropdown panel is not visible

  Scenario: Removing the leading slash closes the dropdown
    Given the user has typed "/gri" and the dropdown is open
    When the user edits the text to "hello"
    Then the dropdown panel is not visible

  Scenario: Subtitle uses help when present, else description
    When the user types "/"
    Then the clear row's subtitle is "/clear" (from help)
    And the compact row's subtitle is "/compact [prompt]" (from help)
    And the review-checklist row's subtitle is "/review-checklist" (from help)
    And the grill-me row's subtitle is "Grills with questions." (from description, help is nil)

  Scenario: Tier ordering preserved in filtered results
    When the user types "/" and the dropdown lists all matches
    Then within the filtered list, builtins come first (alphabetical)
    Then commands come next (alphabetical)
    Then skills come last (alphabetical)
    # the filter removes non-matches but does not re-sort

  Scenario: Disabled-invocation skills appear with a manual badge
    When the user types "/"
    Then grill-me appears with a "manual" badge
    And grind-it and brew-coffee appear without the badge

  Scenario: Dropdown is positioned above the textarea
    When the dropdown opens
    Then the panel's bottom edge is at or above the textarea's top edge
    And the panel remains correctly positioned on window scroll/resize
```

## Test Cases

In `planck_cli/test/planck/web/live/prompt_input_test.exs`:

- `describe "slash autocomplete dropdown"`:
  - typing `/` renders the dropdown with all commands in tier order
    (builtins → commands → skills, alphabetical within each tier)
  - typing `/gri` filters to grill-me + grind-it (both skills)
  - typing `/c` filters to clear + compact (both builtins)
  - typing `/co` filters to compact (builtin) + brew-coffee (skill), with
    compact before brew-coffee (tier order preserved)
  - typing `/GRI` is case-insensitive
  - typing `/xyz` renders no dropdown (no matches)
  - editing `/gri` to `hello` closes the dropdown
  - dropdown markup is absent when text doesn't start with `/` (regression
    guard: non-slash input is unaffected)
- `describe "dropdown row rendering"`:
  - built-in rows show a "builtin" type badge
  - command rows show a "command" type badge
  - skill rows show no type badge
  - disabled-invocation skill rows show a "manual" badge; enabled skills
    do not
  - subtitle is `help` when present, else `description` (assert the
    subtitle text for a skill row matches its `description` since skills
    have `help: nil`)
- `describe "dropdown positioning"`:
  - the rendered panel has positioning attributes / hook indicating
    above-textarea placement (assert the hook is attached or the
    positioning class is present; full pixel-level positioning is a JS
    concern, lightly asserted here)

## Files touched

| File | Change |
|---|---|
| `planck_cli/lib/planck/web/live/prompt_input.ex` | extend `change` handler: detect `/`, filter matches across `commands` assign, set `:dropdown_open`/`:command_matches` |
| `planck_cli/lib/planck/web/live/prompt_input.html.heex` | conditional dropdown panel markup with match rows (name + help/description subtitle + type badge + manual badge) |
| `planck_cli/assets/js/app.js` | (possibly) new `CommandDropdown` hook or `position: :above` option on `FloatingDropdown` |
| `planck_cli/test/planck/web/live/prompt_input_test.exs` | dropdown render + filter + close + row-rendering cases |
