# Step 5 — Pass the flattened command list from `ResourceStore` to `PromptInput`

Part of [v0.3.0-spec](../v0.3.0-spec.md). Depends on
[Step 4](step-4-slash-command-backend.md) (for the `ResourceStore.commands`
field and the built-in primitives the dropdown must surface).

## Description

Make the full command set — built-in primitives (`/clear`, `/compact`),
custom commands, and skills (including `disable_model_invocation: true`
ones) — available to the `PromptInput` LiveComponent as a single flattened
`commands` assign, so the dropdown in [Step 6](step-6-ui-dropdown.md) can
render and filter across all three tiers in one list.

[Step 4](step-4-slash-command-backend.md) adds `ResourceStore.commands`
(loaded from `Config.commands_dirs`). `ResourceStore.skills` already holds
the full, unfiltered skill list (Step 2 filters only at the agent-pool
wiring points, not at load time). The parent LiveView (`session_live.ex`)
already reads from `ResourceStore` at mount (e.g. line 49 reads `.teams`).
This step adds reads of `.commands` and `.skills`, projects them into a
uniform shape, concatenates with the built-in primitives, and passes the
result down to `PromptInput` as a `commands` assign.

### Assign shape

Each entry is a lightweight map — just the fields the dropdown needs, to
avoid pushing full `Skill.t` / `Command.t` structs (with file paths and
template bodies) to the UI:

```elixir
%{
  name: String.t(),
  description: String.t(),
  kind: :builtin | :command | :skill,
  disable_model_invocation: boolean(),
  help: String.t() | nil
}
```

### Data sources

- **Built-ins** — a hardcoded list in `session_live.ex` (or a helper in
  `planck_cli`):

  | name | description | kind | disable_model_invocation | help |
  |---|---|---|---|---|
  | `clear` | Delete all messages in the session. | `:builtin` | `true` | `/clear` |
  | `compact` | Compact the session using the compactor. | `:builtin` | `true` | `/compact [prompt]` |

  Both built-ins are marked `disable_model_invocation: true` — they are
  never model-invokable (there is no `run_command` tool for them).

- **Custom commands** — `ResourceStore.get().commands` projected to the
  map shape (`name`, `description`, `kind: :command`,
  `disable_model_invocation`, `help`).

- **Skills** — `ResourceStore.get().skills` projected to the map shape
  (`name`, `description`, `kind: :skill`, `disable_model_invocation`,
  `help: nil` — skills don't have a `help` field; the dropdown falls back
  to `description` as the subtitle per [Step 6]).

### Ordering

The flattened list is ordered by tier (matching the dispatcher's
precedence in [Step 4]), then alphabetical by `name` within each tier:

1. Built-ins (`clear`, `compact`)
2. Custom commands (alphabetical)
3. Skills (alphabetical)

This ordering is preserved verbatim in the dropdown rendering
([Step 6](step-6-ui-dropdown.md)) so the user sees primitives first,
matching the resolution order the backend uses.

### TDD order

1. Write a `prompt_input_test.exs` case asserting the component receives a
   `commands` assign with the expected shape and ordering when rendered by
   the parent LiveView (see Test Cases).
2. Run — it fails (no `commands` assign exists; the old `skills` assign
   from the v0.2.6 design is not present either).
3. Add the `ResourceStore.get().commands` + `.skills` reads, the built-in
   list, the projection + concatenation, and the assign pass-through.
4. Run — test passes.

## Definition of Done

- [ ] `session_live.ex` reads `ResourceStore.get().commands` and
      `ResourceStore.get().skills` (alongside the existing `.teams` read)
      and builds a single flattened `commands` list.
- [ ] The list includes the two built-in primitives (`clear`, `compact`)
      as `kind: :builtin` entries.
- [ ] The list includes every custom command in the store as
      `kind: :command`.
- [ ] The list includes every skill in the store, including
      disabled-invocation ones, as `kind: :skill` (the dropdown needs the
      full set).
- [ ] Each entry has at least `name`, `description`, `kind`,
      `disable_model_invocation`, and `help`.
- [ ] The list is ordered by tier (builtins → commands → skills), then
      alphabetical by `name` within each tier.
- [ ] `PromptInput` accepts and stores the `commands` assign in its
      `update/2` callback (`prompt_input.ex:16`). The old `skills` assign
      from the v0.2.6 design is not used.
- [ ] Hot reload: when `ResourceStore.reload/0` runs (file watcher), the
      parent LiveView re-reads `.commands` and `.skills` and pushes the
      updated `commands` list to `PromptInput`. (Confirm whether
      `session_live` already re-reads `ResourceStore` on reload events; if
      not, add a handler — it likely already does for `.teams`.)
- [ ] No behavioural change yet — the dropdown rendering is [Step 6]. This
      step only wires the data.
- [ ] `mix test` in `planck_cli` passes.
- [ ] `./check planck_cli` passes.

## Use Cases

```gherkin
Feature: PromptInput receives the flattened command list

  Background:
    Given ResourceStore is loaded with:
      | kind    | name             | description              | disable_model_invocation | help                |
      | skill   | self-skill       | A self-loadable skill.    | false                     | nil                 |
      | skill   | gated-skill      | A gated skill.           | true                      | nil                 |
      | command | review-checklist | Runs the review checklist. | true                     | "/review-checklist" |
    And the built-in primitives are clear and compact

  Scenario: PromptInput receives all commands as a single assign
    When the session LiveView mounts
    And renders the PromptInput component
    Then the PromptInput's assigns include a "commands" list
    And the list contains entries for clear, compact, review-checklist, self-skill, and gated-skill
    And each entry has name, description, kind, disable_model_invocation, and help fields

  Scenario: List is ordered by tier then alphabetical
    When the PromptInput receives the commands assign
    Then the list is ordered:
      | #  | name             | kind     |
      | 1  | clear            | builtin  |
      | 2  | compact          | builtin  |
      | 3  | review-checklist | command  |
      | 4  | gated-skill      | skill    |
      | 5  | self-skill       | skill    |
    # builtins first, then commands, then skills; alphabetical within each tier

  Scenario: Kind field distinguishes tiers
    When the PromptInput receives the commands assign
    Then the "clear" entry has kind == :builtin
    And the "review-checklist" entry has kind == :command
    And the "self-skill" entry has kind == :skill

  Scenario: Disabled-invocation flag is carried through for all kinds
    When the PromptInput receives the commands assign
    Then the "gated-skill" entry has disable_model_invocation == true
    And the "self-skill" entry has disable_model_invocation == false
    And the "clear" entry has disable_model_invocation == true
    And the "review-checklist" entry has disable_model_invocation == true

  Scenario: Help field is carried through where present
    When the PromptInput receives the commands assign
    Then the "compact" entry has help == "/compact [prompt]"
    And the "review-checklist" entry has help == "/review-checklist"
    And the "self-skill" entry has help == nil
    # skills don't have a help field; the dropdown falls back to description

  Scenario: Command list updates on hot reload
    Given the session is mounted with the initial command list
    When a new command "fresh-command" is added to the commands directory
    And the file watcher triggers ResourceStore.reload/0
    Then the PromptInput's commands assign includes "fresh-command" as kind :command

  Scenario: No rendering change yet
    When the PromptInput renders with the commands assign
    Then the rendered HTML is identical to before this step
    # the dropdown is added in Step 6, not here
```

## Test Cases

In `planck_cli/test/planck/web/live/prompt_input_test.exs` (or
`session_live_test.exs`, matching existing test organization):

- `describe "commands assign"`:
  - rendering `PromptInput` via the parent LiveView with a ResourceStore
    containing two skills (one disabled), one custom command, plus the
    built-in primitives produces a `commands` assign with 6 entries.
  - each entry carries `name`, `description`, `kind`,
    `disable_model_invocation`, `help`.
  - the list is ordered by tier (builtins → commands → skills), then
    alphabetical within each tier.
  - the `kind` field correctly tags each entry.
  - the disabled skill's `disable_model_invocation` is `true` in the
    assign; the built-ins are `true`; the enabled skill is `false`.
- `describe "hot reload updates the command list"`:
  - after `ResourceStore.reload/0` with a newly-added command, the
    `PromptInput` `commands` assign includes the new command as
    `kind: :command`.
  - after `ResourceStore.reload/0` with a newly-added skill, the
    `commands` assign includes the new skill as `kind: :skill`.

These tests touch `ResourceStore` (global state) → `async: false`.

## Files touched

| File | Change |
|---|---|
| `planck_cli/lib/planck/web/live/session_live.ex` | read `ResourceStore.get().commands` + `.skills`, define built-in primitives, build flattened + ordered `commands` list, pass to `PromptInput` |
| `planck_cli/lib/planck/web/live/prompt_input.ex` | accept + store `commands` in `update/2` (replaces the v0.2.6-era `skills` assign) |
| `planck_cli/lib/planck/web/live/session_live.html.heex` | pass `commands={...}` to the `.live_component` (line 50-55) |
| `planck_cli/test/.../prompt_input_test.exs` (or `session_live_test.exs`) | commands-assign + hot-reload cases |
