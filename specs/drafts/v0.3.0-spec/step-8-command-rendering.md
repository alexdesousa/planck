# Step 8 — In-chat rendering of dispatched commands (persisted + queued)

Part of [v0.3.0-spec](../v0.3.0-spec.md). Depends on
[Step 4](step-4-slash-command-backend.md) (for the unified command queue,
`Agent.command/3`, `Agent.cancel_queued/2`, and the `role` field on the
`:message_queued` broadcast).

Independent of the dropdown steps ([5](step-5-ui-skill-list.md),
[6](step-6-ui-dropdown.md), [7](step-7-ui-keyboard-mouse.md)) — those cover
command *discovery and selection* in the prompt input; this step covers how
a *dispatched* command renders in the conversation list.

## Description

Today a dispatched custom command renders as an ordinary editable user
message — because the agent enqueued it via the `:command` opt on
`Agent.prompt/3`, and the `:message_queued` broadcast carried no role, so
the UI's `ChatComponent` pushed a plain `new_pending_entry` (right side,
`:user`, editable). Likewise, queued `/clear` and `/compact` primitives
were invisible (held in `PendingCommands`, never rendered) until the turn
boundary executed them.

[Step 4](step-4-slash-command-backend.md) changes the backend so:

- Custom commands are enqueued via `Agent.command/3` as `{:custom, :command}`
  messages, and the `:message_queued` broadcast now carries
  `role: :command` + `command_meta`.
- `/clear` and `/compact` primitives (when the agent is busy) are enqueued
  as `{:custom, :clear}` / `{:custom, :compact}` messages, and the
  `:message_queued` broadcast carries `role: :clear` / `:compact`.
- Any queued message (user, command, clear, compact) can be cancelled via
  the new `Agent.cancel_queued/2`.

This step makes the UI reflect that: dispatched commands render distinctly
from ordinary user messages, with a header chip, a collapsible rendered
body, and (while queued) a delete button instead of an edit button.

### Entry shape — `ChatEntries`

`ChatEntries.entry_type()` (chat_entries.ex:97) gains a `:command` type and
new optional fields:

| Field | Type | Used by |
|---|---|---|
| `command` | `String.t()` | the command name (e.g. `"review-checklist"`) |
| `command_args` | `String.t() \| nil` | the raw trailing args |
| `invoked_by` | `:user \| :agent` | who invoked it (drives styling) |
| `deletable` | `boolean()` | whether the delete button renders (queued only) |

The existing `expanded` field (already on the entry type) is reused for
the collapsible body's toggle state, the same way `:thinking` and `:tool`
entries use it today (chat_component.html.heex:128, 153).

#### Factories

```elixir
# Persisted command — rendered in the main entry list (left or right side)
@spec new_command_entry(String.t(), String.t(), String.t() | nil, :user | :agent, String.t()) ::
        entry()
def new_command_entry(id, command, args, invoked_by, body) do
  %{
    id: id,
    type: :command,
    side: if(invoked_by == :user, do: :right, else: :left),
    author: if(invoked_by == :user, do: :user, else: {:agent, nil}),
    command: command,
    command_args: args,
    invoked_by: invoked_by,
    text: body,
    expanded: false,
    streaming: false,
    timestamp: DateTime.utc_now()
  }
end

# Queued command — rendered in pending_entries while the agent is busy.
# Non-editable; deletable. body is nil for /clear and /compact.
@spec new_pending_command_entry(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
        entry()
def new_pending_command_entry(id, command, args, body) do
  %{
    id: id,
    type: :command,
    side: :right,
    author: :user,
    command: command,
    command_args: args,
    invoked_by: :user,
    text: body,
    expanded: false,
    streaming: false,
    pending: true,
    deletable: true,
    timestamp: DateTime.utc_now()
  }
end
```

For `/clear` and `/compact`, the `command` field is `"clear"` / `"compact"`
and `body` is `nil` (no rendered body to show); the chip is the whole
entry. For custom commands, `body` is the rendered EEx template text.

#### `classify_row` clause

`ChatEntries.classify_row/4` (chat_entries.ex:522 currently drops
`{:custom, :command}` via the `_ -> []` catch-all) gains an explicit
clause:

```elixir
%{role: {:custom, :command}} = msg ->
  %{command: name, args: args, invoked_by: invoked_by} = msg.metadata
  body = extract_text(msg.content)
  [new_command_entry(msg.id, name, args, invoked_by, body)]
```

No `:clear` / `:compact` clause is needed — those markers are consumed by
`drain_control_markers` at the turn boundary (Step 4) and never persisted,
so they never appear in the loaded entry list.

### Event handling — `ChatComponent`

#### `:message_queued` split

`ChatComponent.handle_agent_event/2` (chat_component.ex:254) currently
treats every `:message_queued` as an editable user pending entry. It now
branches on the `role` field Step 4 adds to the payload:

| Payload `role` | Action |
|---|---|
| `:command` | push `new_pending_command_entry(id, meta.command, meta.args, extract_text(content))` |
| `:clear` | push `new_pending_command_entry(id, "clear", nil, nil)` |
| `:compact` | push `new_pending_command_entry(id, "compact", meta.args, nil)` |
| absent (plain user message) | existing `new_pending_entry(id, text, editable)` path — unchanged |

Command pending entries are **not** marked `editable`; existing pending
user entries stay editable (and, as today, only the most recent is
editable — the others get `editable: false`). Command entries never get
the edit button regardless of position.

#### `delete_pending_command` event

New `handle_event("delete_pending_command", %{"id" => id})` in
`ChatComponent`:

1. Calls `Headless.cancel_queued_message(socket.assigns.session_id, id)`.
2. On `:ok` → removes the entry with that `id` from `pending_entries`.
3. On `{:error, :already_sent}` or `{:error, :not_found}` → no-op (the
   message has already been processed or is gone; the pending entry will
   be cleared on the next `:messages_flushed` reload anyway). Optionally a
   brief toast — decide during implementation; simplest is a silent no-op.

No optimistic removal: wait for the `:ok` reply so a failed cancel leaves
the entry in place (the agent is still going to process it).

#### `toggle_entry` reuse

The existing `toggle_entry` event (chat_component.ex — already used by
`:thinking` / `:tool` / `:error` entries to flip `expanded`) is reused
for `:command` entries. No new event needed for the collapse toggle.

### `Headless` passthrough

New `Planck.Headless.cancel_queued_message/2`:

```elixir
@spec cancel_queued_message(session_id(), String.t()) ::
        :ok | {:error, :not_found} | {:error, :already_sent}
def cancel_queued_message(session_id, id) do
  with {:ok, team_id} <- read_team_id(session_id),
       {:ok, pid} <- find_orchestrator(team_id) do
    Agent.cancel_queued(pid, id)
  end
end
```

Mirrors the `find_orchestrator` lookup used by `prompt/3`
(headless.ex:188).

### Template — `chat_component.html.heex`

#### Persisted `:command` entry (in the main `@entries` loop)

A header chip (`/<name> <args>`) styled like the existing `:tool` /
`:thinking` collapsible headers (NeoBrutalism border + shadow, a `▶`/`▼`
toggle via `phx-click="toggle_entry"`). The rendered body (markdown) is in
the collapsible region below, shown when `entry.expanded` is true — same
pattern as `:thinking` (chat_component.html.heex:118-141).

- `invoked_by: :user` → right side, `border-black` (matches user styling).
- `invoked_by: :agent` → left side, `border-dashed` + muted
  (`text-muted-foreground`), to visually distinguish agent-invoked
  commands from user-invoked ones.

When `body` is `nil` (`/clear`, `/compact` — though these don't normally
persist, the clause is defensive), only the chip renders, no collapsible
region.

#### Queued `:command` entry (in the `@pending_entries` loop)

The existing pending block (chat_component.html.heex:275-304) gains a
branch: when `entry.type == :command`, render a chip with:

- The `/<name>` header (and args if present).
- A delete button (`phx-click="delete_pending_command"`,
  `phx-value-id={entry.id}`) instead of the edit button.
- A "queued" label, matching the existing pending styling
  (`opacity-70`, `bg-muted`).
- No collapsible body for `/clear` / `/compact` (body is nil); a
  collapsible body for custom commands (optional — simplest is to show
  the body inline when present, since queued entries are transient).

### Out of scope

- **Editing queued commands** (re-rendering with new args) — explicitly
  not supported (see top-level spec "Explicitly not touched"). Delete +
  re-dispatch is the path.
- **Persisting `:clear` / `:compact` markers** — they're consumed at the
  turn boundary and never reach the loaded entry list; no rendering
  needed for them in the persisted list.
- **Agent-invoked command rendering details** — the `invoked_by: :agent`
  styling clause is added now so it works when the follow-up `run_command`
  tool lands, but there's no agent-invoked path to test end-to-end in
  v0.3.0.

### TDD order

1. Write `chat_entries_test.exs` cases for `new_command_entry/5` and
   `new_pending_command_entry/4` (shape, side/author by `invoked_by`,
   `deletable` flag).
2. Write `chat_entries_test.exs` cases for `classify_row` emitting a
   `:command` entry from a `{:custom, :command}` message for both
   `invoked_by: :user` and `invoked_by: :agent`.
3. Write `chat_component_test.exs` cases for the `:message_queued` split:
   `role: :command` → pending command entry (deletable, not editable);
   `role: :clear` / `:compact` → pending command chip; no role → existing
   editable user entry.
4. Write a `chat_component_test.exs` case for `delete_pending_command`:
   calls `Headless.cancel_queued_message/2`, removes the entry on `:ok`,
   no-ops on `:already_sent`.
5. Write a `headless_test.exs` case for `cancel_queued_message/2`
   routing to `Agent.cancel_queued/2` via the orchestrator lookup.
6. Run — fail. Implement. Run — pass. `./check planck_cli` and
   `./check planck_headless`.

## Definition of Done

- [ ] `ChatEntries.entry_type()` includes `:command` and the optional
      `command`, `command_args`, `invoked_by`, `deletable` fields.
- [ ] `new_command_entry/5` builds a persisted command entry; side/author
      driven by `invoked_by` (`:user` → right/user, `:agent` →
      left/agent-muted).
- [ ] `new_pending_command_entry/4` builds a queued command entry:
      `pending: true`, `deletable: true`, not editable.
- [ ] `classify_row` has a `{:custom, :command}` clause producing a
      `:command` entry from `msg.metadata` + `extract_text(msg.content)`
      (replaces the current `_ -> []` drop for this role).
- [ ] `ChatComponent.handle_agent_event(:message_queued, ...)` branches
      on `role`: `:command` / `:clear` / `:compact` → pending command
      entry; absent → existing editable user entry.
- [ ] Queued command entries render with a delete button
      (`phx-click="delete_pending_command"`), not an edit button.
- [ ] `ChatComponent.handle_event("delete_pending_command", ...)` calls
      `Headless.cancel_queued_message/2`, removes the entry on `:ok`,
      no-ops on `:already_sent` / `:not_found`.
- [ ] `Planck.Headless.cancel_queued_message/2` exists, routes to
      `Agent.cancel_queued/2` via `find_orchestrator`.
- [ ] Persisted `:command` entries render in `chat_component.html.heex`
      as a header chip (`/<name> <args>`) with a collapsible rendered body
      toggled by `expanded` (reuse `toggle_entry`).
- [ ] `invoked_by: :agent` entries use muted/left styling distinct from
      `invoked_by: :user` (right, user styling).
- [ ] Queued `/clear` / `/compact` chips render with no body (body is
      nil); custom command chips render the body (inline or collapsible).
- [ ] `mix test` in `planck_cli` and `planck_headless` passes.
- [ ] `./check planck_cli` and `./check planck_headless` pass.

## Use Cases

```gherkin
Feature: Dispatched commands render distinctly in the chat

  Background:
    Given a custom command "review-checklist" exists with an EEx body
    And the agent is idle

  # Persisted command (user-invoked)

  Scenario: A user-invoked custom command renders as a collapsible chip
    When the user submits "/review-checklist src/auth"
    Then the chat list shows a :command entry on the right side
    And the entry header is "/review-checklist src/auth"
    And the rendered body is collapsed by default
    When the user clicks the header
    Then the rendered body expands (markdown rendered)
    And clicking again collapses it

  Scenario: A user-invoked command with no args
    When the user submits "/review-checklist"
    Then the header is "/review-checklist" (no trailing args)

  Scenario: An agent-invoked command renders with muted left styling
    Given a {:custom, :command} message is persisted with invoked_by: :agent
    When the chat list loads
    Then the entry is on the left side
    And the styling is muted (distinct from user-invoked right-side styling)
    # defensive clause — no agent-invoked path exists in v0.3.0 yet

  # Queued command (while agent is busy)

  Scenario: A queued custom command renders as a deletable chip
    Given the agent is streaming a turn
    When the user submits "/review-checklist src/auth"
    Then a :message_queued event with role: :command is received
    And the pending list shows a command chip "/review-checklist src/auth"
    And the chip has a delete button (not an edit button)
    And the chip is not editable

  Scenario: A queued /clear renders as a deletable chip with no body
    Given the agent is streaming a turn
    When the user submits "/clear"
    Then a :message_queued event with role: :clear is received
    And the pending list shows a command chip "/clear"
    And the chip has a delete button
    And the chip has no collapsible body

  Scenario: A queued /compact renders as a deletable chip with no body
    Given the agent is streaming a turn
    When the user submits "/compact preserve paths"
    Then a :message_queued event with role: :compact is received
    And the pending list shows a command chip "/compact preserve paths"
    And the chip has a delete button

  Scenario: Deleting a queued command removes it from the pending list
    Given a queued command chip is shown
    When the user clicks the delete button
    Then Headless.cancel_queued_message/2 is called with the chip's id
    And on :ok the chip is removed from the pending list
    And the agent no longer processes that command

  Scenario: Delete no-ops if the message was already flushed
    Given a queued command chip is shown but the agent just flushed it
    When the user clicks delete
    Then cancel_queued returns {:error, :already_sent}
    And the chip remains until the next :messages_flushed reload clears it

  Scenario: Cancelling a queued /clear
    Given a queued /clear chip is shown
    When the user clicks delete
    Then the :clear marker is removed from the agent's state.messages
    And the chip disappears
    # previously impossible — PendingCommands had no cancel path

  # Ordinary user messages are unaffected

  Scenario: A queued ordinary user message still renders as editable
    Given the agent is streaming a turn
    When the user submits "hello there"
    Then a :message_queued event with no role is received
    And the pending list shows an editable user entry (not a command chip)
    And it has an edit button (not a delete button)
```

## Test Cases

In `planck_cli/test/planck/web/live/chat_entries_test.exs` (or
`chat_component_test.exs`, matching existing test organization):

- `describe "new_command_entry/5"`:
  - `invoked_by: :user` → `side: :right`, `author: :user`
  - `invoked_by: :agent` → `side: :left`, agent author
  - `expanded: false` by default
- `describe "new_pending_command_entry/4"`:
  - `pending: true`, `deletable: true`, no `editable` field (or `false`)
- `describe "classify_row {:custom, :command}"`:
  - `invoked_by: :user` → `:command` entry, right side
  - `invoked_by: :agent` → `:command` entry, left side
  - `command` / `command_args` pulled from metadata, body from
    `extract_text(content)`
- `describe ":message_queued role split"`:
  - `role: :command` + `command_meta` → pending command entry with the
    command name + args from meta
  - `role: :clear` → pending command chip "clear", no body
  - `role: :compact` + `args` → pending command chip "compact" with args
  - no role → existing editable user pending entry (regression guard)

In `planck_cli/test/planck/web/live/chat_component_test.exs`:

- `describe "delete_pending_command"`:
  - clicks delete → calls `Headless.cancel_queued_message/2` with the id
  - on `:ok` → entry removed from `pending_entries`
  - on `{:error, :already_sent}` → entry remains
  - on `{:error, :not_found}` → entry remains

In `planck_headless/test/planck/headless_test.exs`:

- `describe "cancel_queued_message/2"`:
  - routes to `Agent.cancel_queued/2` via `find_orchestrator`
  - returns `{:error, term()}` when the session/team lookup fails

These tests touch `ResourceStore` / global agent state where relevant →
`async: false`.

## Files touched

| File | Change |
|---|---|
| `planck_cli/lib/planck/web/live/chat_entries.ex` | `:command` entry type + fields; `new_command_entry/5`, `new_pending_command_entry/4`; `{:custom, :command}` clause in `classify_row` |
| `planck_cli/lib/planck/web/live/chat_component.ex` | `:message_queued` role split; `delete_pending_command` event handler |
| `planck_cli/lib/planck/web/live/chat_component.html.heex` | `:command` persisted entry (collapsible chip); queued command chip with delete button (in pending loop) |
| `planck_headless/lib/planck/headless.ex` | `cancel_queued_message/2` passthrough |
| `planck_cli/test/.../chat_entries_test.exs` (or `chat_component_test.exs`) | entry factories + classify_row + message_queued split + delete cases |
| `planck_headless/test/planck/headless_test.exs` | `cancel_queued_message/2` routing case |
