# Step 7 — Keyboard + mouse navigation and textarea insertion

Part of [v0.2.6-spec](../v0.2.6-spec.md). Depends on
[Step 6](step-6-ui-dropdown.md) (for the rendered dropdown).

## Description

Make the autocomplete dropdown from Step 6 interactive: keyboard
navigation (↑/↓ to move selection, Enter to select, Escape to close) and
mouse click selection. On selection, insert `/skill-name ` into the
textarea (with a trailing space for optional extra instructions), close
the dropdown, and refocus the textarea for continued typing.

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

1. Replace the textarea content: set it to `/skill-name ` (the selected
   skill's name with a leading `/` and trailing space). If the user had
   typed a longer prefix (e.g. `/gri`), the whole prefix is replaced —
   the selection is the canonical `/skill-name ` form. If the user had
   typed extra text after a space already, preserve it (edge case; decide
   during implementation — simplest is to replace only the `/prefix`
   token, leaving trailing text intact).
2. Sync the new value back to the LiveView via a `change` event (so
   `:text` stays in sync and the dropdown closes because the text now
   starts with `/skill-name ` followed by a space, which won't match the
   `/skill-name` prefix... actually it will — `/skill-name ` has prefix
   `/skill-name`. Reconsider: after selection, the dropdown should close
   regardless of prefix match, e.g. by tracking a `:selected_skill` flag
   that suppresses re-opening until the text changes again).
3. Close the dropdown.
4. Refocus the textarea, cursor after the inserted space.

The exact "close after select and don't immediately reopen" logic needs
care. One approach: after a selection, set a `:suppress_dropdown` flag
that the `change` handler clears on the *next* text change after the
selection, so the dropdown doesn't pop back open on the inserted
`/skill-name ` text. Resolve during implementation; capture the chosen
approach in this file's Definition of Done.

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
      selection in the dropdown when it's open.
- [ ] Enter, when the dropdown is open, selects the highlighted match and
      does *not* submit the form. Enter when the dropdown is closed submits
      as before (unchanged).
- [ ] Escape closes the dropdown without selecting.
- [ ] Mouse click on a match selects it (same effect as Enter on that
      item).
- [ ] On selection, the textarea content becomes `/skill-name ` (with
      trailing space), the dropdown closes, and the textarea is refocused
      with the cursor after the space.
- [ ] After selection, the dropdown does not immediately re-open on the
      inserted `/skill-name ` text (via a suppress flag or equivalent —
      capture the chosen mechanism here when implemented).
- [ ] The selected text is synced back to the LiveView `:text` assign via
      a `change` event so server state matches the textarea.
- [ ] `mix test` in `planck_cli` passes (whatever JS-testable subset is
      covered; document the manual-verification steps for the rest).
- [ ] `./check planck_cli` passes.

## Use Cases

```gherkin
Feature: Dropdown keyboard and mouse interaction

  Background:
    Given the PromptInput has a skills assign with:
      | name        | disable_model_invocation |
      | grill-me    | true                     |
      | grind-it    | false                    |
      | brew-coffee | false                    |
    And the user has typed "/" so the dropdown is open with all three
      matches, highlight on the first (grill-me)

  Scenario: Arrow down moves the highlight down
    When the user presses ArrowDown
    Then the highlight moves to grind-it
    And pressing ArrowDown again moves it to brew-coffee
    And pressing ArrowDown at the last item wraps to the first (or stays —
      decide during implementation; wrapping is preferred)

  Scenario: Arrow up moves the highlight up
    Given the highlight is on the first item (grill-me)
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
    And on submit, the backend (Step 4) parses grill-me + the extra text
```

## Test Cases

In `planck_cli/test/planck/web/live/prompt_input_test.exs`:

- `describe "dropdown keyboard navigation"`:
  - ArrowDown moves highlight; ArrowUp moves highlight (if the test
    harness supports `render_keydown` / `push_key`; if not, assert the
    hook is wired and the behaviour is manually verified — document).
  - Enter with dropdown open pushes a selection `change` event and does
    not push `submit`.
  - Enter with dropdown closed pushes `submit`.
  - Escape closes the dropdown.
- `describe "dropdown mouse selection"`:
  - `render_click` on a match element pushes the selection `change` event
    with `/skill-name ` as the new text.
- `describe "post-selection state"`:
  - after a selection `change` event, `:text` is `/skill-name `, the
    dropdown is closed (`:dropdown_open == false`), and `:suppress_dropdown`
    (or equivalent) is set so a subsequent no-op `change` doesn't reopen
    it.

Manual verification checklist (JS behaviours not covered by automated
tests — document in the step file when the chosen test harness can't reach
them):

- [ ] ↑/↓ visually move the highlight in a real browser.
- [ ] Enter selects and inserts in a real browser.
- [ ] Escape closes in a real browser.
- [ ] Mouse click selects in a real browser.
- [ ] Cursor lands after the trailing space post-selection.
- [ ] Dropdown stays closed after selection until text changes.

## Files touched

| File | Change |
|---|---|
| `planck_cli/assets/js/app.js` | extend `PromptInput` hook (or add `SkillDropdown` hook) with ↑/↓/Enter/Esc handling + selection insertion |
| `planck_cli/lib/planck/web/live/prompt_input.ex` | handle the selection `change` event: set `:text`, close dropdown, set suppress flag |
| `planck_cli/lib/planck/web/live/prompt_input.html.heex` | add `data-` attributes / `phx-click` on match items for mouse selection + highlight rendering |
| `planck_cli/test/planck/web/live/prompt_input_test.exs` | selection + post-selection state cases |