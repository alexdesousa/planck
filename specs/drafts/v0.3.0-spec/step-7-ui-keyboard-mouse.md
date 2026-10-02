# Step 7 — Keyboard + mouse navigation and textarea insertion

Part of [v0.3.0-spec](../v0.3.0-spec.md). Depends on
[Step 6](step-6-ui-dropdown.md) (for the rendered dropdown).

## Description

Make the autocomplete dropdown from [Step 6](step-6-ui-dropdown.md)
interactive: keyboard navigation (↑/↓ to move selection, Enter to select,
Escape to close) and mouse click selection. On selection, insert
`/command-name ` into the textarea (with a trailing space for optional
extra instructions), close the dropdown, and refocus the textarea for
continued typing.

The interaction is **uniform across all command kinds** — built-ins,
custom commands, and skills are all selected the same way. There is no
per-tier special-casing in the keyboard/mouse logic. In particular, even
`/clear` (which takes no arguments) is inserted as `/clear ` with a
trailing space and requires the user to press Enter again to submit —
there is no auto-submit-on-select behavior.

This is the JS-heavy step. The existing `PromptInput` hook
(`app.js:15-24`) currently only handles Enter-to-submit. Extend it (or add
a companion hook on the dropdown) to handle the open-dropdown key
behaviours, since ↑/↓ and Enter need different behaviour when the dropdown
is open vs closed:

- **Dropdown open:** ↑/↓ move the highlighted index; Enter selects the
  highlighted match (and does *not* submit the form); Escape closes the
  dropdown without selecting.
- **Dropdown closed:** Enter submits as today (unchanged).

Mouse: clicking a match selects it (same effect as Enter on that item).

### Selection insertion

On selection (keyboard or mouse):

1. Replace the textarea content: set it to `/command-name ` (the selected
   command's name with a leading `/` and trailing space). If the user had
   typed a longer prefix (e.g. `/gri`), the whole prefix is replaced —
   the selection is the canonical `/command-name ` form. If the user had
   typed extra text after a space already, preserve it (edge case; decide
   during implementation — simplest is to replace only the `/prefix`
   token, leaving trailing text intact).
2. Sync the new value back to the LiveView via a `change` event (so
   `:text` stays in sync and the dropdown closes because the text now
   starts with `/command-name ` followed by a space, which won't match
   the `/command-name` prefix... actually it will — `/command-name ` has
   prefix `/command-name`. Reconsider: after selection, the dropdown
   should close regardless of prefix match, e.g. by tracking a
   `:selected_command` flag that suppresses re-opening until the text
   changes again).
3. Close the dropdown.
4. Refocus the textarea, cursor after the inserted space.

The exact "close after select and don't immediately reopen" logic needs
care. One approach: after a selection, set a `:suppress_dropdown` flag
that the `change` handler clears on the *next* text change after the
selection, so the dropdown doesn't pop back open on the inserted
`/command-name ` text. Resolve during implementation; capture the chosen
approach in this file's Definition of Done.

### No auto-submit for built-ins

Per the design decision: selecting `/clear` from the dropdown inserts
`/clear ` (with trailing space) and closes the dropdown, just like every
other command. The user then presses Enter to submit. This keeps the
selection logic uniform across all tiers and avoids per-kind branching in
the JS hook. The cost is one extra keystroke for the no-argument
primitive `/clear`, which is acceptable for consistency.

### TDD order

JS behaviour is harder to unit-test in this stack. Prefer LiveView
integration tests (`live_isolated`/`render_keydown` where available) for
the keyboard paths, and verify mouse-click via `render_click` on a match
element. If the existing test suite has no JS-keydown testing harness,
fall back to testing the *Elixir-side* effects (the `change` event the
hook pushes after selection) and document the JS behaviour as
manually-verified.

## Definition of Done

- [ ] The `PromptInput` JS hook handles ↑/↓ to move a highlighted
      selection in the dropdown when it's open. Wrapping from last to
      first (and vice versa) is preferred.
- [ ] Enter, when the dropdown is open, selects the highlighted match and
      does *not* submit the form. Enter when the dropdown is closed
      submits as before (unchanged).
- [ ] Escape closes the dropdown without selecting.
- [ ] Mouse click on a match selects it (same effect as Enter on that
      item).
- [ ] On selection, the textarea content becomes `/command-name ` (with
      trailing space), the dropdown closes, and the textarea is refocused
      with the cursor after the space.
- [ ] Selection behavior is uniform across all command kinds — no
      per-tier branching. `/clear` is inserted as `/clear ` and requires
      a separate Enter to submit (no auto-submit).
- [ ] After selection, the dropdown does not immediately re-open on the
      inserted `/command-name ` text (via a suppress flag or equivalent —
      capture the chosen mechanism here when implemented).
- [ ] The selected text is synced back to the LiveView `:text` assign via
      a `change` event so server state matches the textarea.
- [ ] `mix test` in `planck_cli` passes (whatever JS-testable subset is
      covered; document the manual-verification steps for the rest).
- [ ] `./check planck_cli` passes.

## Use Cases

```gherkin
Feature: Dropdown keyboard and mouse interaction (uniform across tiers)

  Background:
    Given the PromptInput has a commands assign with:
      | name             | kind    | disable_model_invocation |
      | clear            | builtin | true                     |
      | compact          | builtin | true                     |
      | review-checklist | command | true                     |
      | grill-me         | skill   | true                     |
      | grind-it         | skill   | false                    |
      | brew-coffee      | skill   | false                    |
    And the user has typed "/" so the dropdown is open with all six
      matches, highlight on the first (clear)

  Scenario: Arrow down moves the highlight down
    When the user presses ArrowDown
    Then the highlight moves to compact
    And pressing ArrowDown again moves it to review-checklist
    And pressing ArrowDown again moves it to grill-me
    And pressing ArrowDown at the last item (brew-coffee) wraps to the first (clear)

  Scenario: Arrow up moves the highlight up
    Given the highlight is on the first item (clear)
    When the user presses ArrowUp
    Then the highlight moves to the last item (brew-coffee)
    # wrapping from first to last

  Scenario: Enter selects the highlighted match
    Given the highlight is on grill-me
    When the user presses Enter
    Then the textarea content becomes "/grill-me "
    And the dropdown closes
    And the textarea is focused with the cursor after the trailing space
    And the form is not submitted

  Scenario: Enter does not submit while dropdown is open
    Given the dropdown is open
    When the user presses Enter
    Then no {:prompt_submit, ...} message is sent

  Scenario: Enter submits as normal when dropdown is closed
    Given the textarea contains "hello" and the dropdown is closed
    When the user presses Enter
    Then the form submits and {:prompt_submit, "hello"} is sent

  Scenario: Escape closes the dropdown without selecting
    Given the dropdown is open with highlight on grind-it
    When the user presses Escape
    Then the dropdown closes
    And the textarea content is unchanged
    And the textarea remains focused

  Scenario: Mouse click selects the clicked match
    Given the dropdown is open
    When the user clicks brew-coffee
    Then the textarea content becomes "/brew-coffee "
    And the dropdown closes
    And the textarea is focused after the trailing space

  Scenario: Selecting a built-in does not auto-submit
    Given the dropdown is open with highlight on clear
    When the user presses Enter
    Then the textarea content becomes "/clear "
    And the dropdown closes
    And the form is NOT submitted
    # /clear requires a separate Enter press to submit, uniform with other commands

  Scenario: Dropdown does not reopen immediately after selection
    Given the user just selected grill-me and the textarea shows
        "/grill-me "
    When the cursor remains in the textarea without further editing
    Then the dropdown does not re-open

  Scenario: Editing after selection re-enables the dropdown
    Given the user selected grill-me and the textarea shows "/grill-me "
    When the user deletes back to "/grill-m" and types "e" again
        restoring "/grill-me "
    Then ... (decide: re-open or stay closed? preferred: stay closed until
      the text actually changes the prefix — capture here)

  Scenario: Typing extra instructions after selection
    Given the user selected grill-me and the textarea shows "/grill-me "
    When the user types "give me five questions"
    Then the textarea shows "/grill-me give me five questions"
    And the dropdown stays closed
    And on submit, the backend ([Step 4]) parses grill-me + the extra text

  Scenario: Selection works uniformly across all kinds
    Given the dropdown is open
    When the user selects clear (builtin)
    Then the textarea shows "/clear "
    When the user clears the textarea, types "/", and selects review-checklist (command)
    Then the textarea shows "/review-checklist "
    When the user clears the textarea, types "/", and selects brew-coffee (skill)
    Then the textarea shows "/brew-coffee "
    # identical insertion behavior regardless of kind
```

## Test Cases

In `planck_cli/test/planck/web/live/prompt_input_test.exs`:

- `describe "dropdown keyboard navigation"`:
  - ArrowDown moves highlight; ArrowUp moves highlight (if the test
    harness supports `render_keydown` / `push_key`; if not, assert the
    hook is wired and the behaviour is manually verified — document).
  - ArrowDown at the last item wraps to the first; ArrowUp at the first
    wraps to the last.
  - Enter with dropdown open pushes a selection `change` event and does
    not push `submit`.
  - Enter with dropdown closed pushes `submit`.
  - Escape closes the dropdown.
- `describe "dropdown mouse selection"`:
  - `render_click` on a match element pushes the selection `change` event
    with `/command-name ` as the new text.
- `describe "selection uniformity across kinds"`:
  - selecting a `:builtin` entry inserts `/name ` and does not submit
  - selecting a `:command` entry inserts `/name ` and does not submit
  - selecting a `:skill` entry inserts `/name ` and does not submit
  - all three produce the same `change` event shape (regression guard
    against per-tier branching)
- `describe "post-selection state"`:
  - after a selection `change` event, `:text` is `/command-name `, the
    dropdown is closed (`:dropdown_open == false`), and
    `:suppress_dropdown` (or equivalent) is set so a subsequent no-op
    `change` doesn't reopen it.

Manual verification checklist (JS behaviours not covered by automated
tests — document in the step file when the chosen test harness can't reach
them):

- [ ] ↑/↓ visually move the highlight in a real browser.
- [ ] ↑/↓ wrapping works (last → first, first → last).
- [ ] Enter selects and inserts in a real browser.
- [ ] Enter does not submit while the dropdown is open.
- [ ] Escape closes in a real browser.
- [ ] Mouse click selects in a real browser.
- [ ] Cursor lands after the trailing space post-selection.
- [ ] Dropdown stays closed after selection until text changes.
- [ ] Selecting `/clear` does not auto-submit (requires a second Enter).

## Files touched

| File | Change |
|---|---|
| `planck_cli/assets/js/app.js` | extend `PromptInput` hook (or add `CommandDropdown` hook) with ↑/↓/Enter/Esc handling + selection insertion (uniform across kinds) |
| `planck_cli/lib/planck/web/live/prompt_input.ex` | handle the selection `change` event: set `:text`, close dropdown, set suppress flag |
| `planck_cli/lib/planck/web/live/prompt_input.html.heex` | add `data-` attributes / `phx-click` on match items for mouse selection + highlight rendering |
| `planck_cli/test/planck/web/live/prompt_input_test.exs` | selection + post-selection state + uniformity cases |
