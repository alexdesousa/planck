# Step 4 — Slash command dispatcher (primitives + custom commands + skills)

Part of [v0.3.0-spec](../v0.3.0-spec.md). Depends on
[Step 1](step-1-frontmatter-field.md).

## Description

Generalize `Planck.Headless.prompt/3` from a thin pass-through into a
**command dispatcher**. When a user submits a message starting with
`/<command-name>` (optionally followed by extra text), the dispatcher
resolves the name against three precedence tiers and executes the first
match:

| Tier | Match source | Action |
|---|---|---|
| 1. Built-in primitives | `/clear`, `/compact [prompt]` | `Agent.clear/1` or `Agent.compact/2` |
| 2. Custom commands | `ResourceStore.get().commands` by name | Enqueue a `{:custom, :command}` message with an EEx-rendered body |
| 3. Skills | `ResourceStore.get().skills` by name (full, unfiltered) | Synthetic `load_skill` tool-call + tool-result pair, then the user's text |
| — | No match | Pass the message through verbatim as a normal user message |

Because parsing lives in `Headless.prompt/3` (the single chokepoint both the
LiveView and the HTTP API `SessionController.prompt` at
`session_controller.ex:144` funnel through), all three tiers are available
to both paths for free.

This step supersedes the original v0.2.6 step-4 design (which only handled
skill loading). The skill-loading tier (3) preserves that original behavior
unchanged; tiers 1 and 2 are new.

### Tier 1 — Built-in primitives

#### `/clear`

Deletes every message in the session and resets the agent's in-memory
message list, leaving an empty conversation. The session process itself
stays alive and its metadata (session id, team id, name) is preserved. No
LLM call is made.

- New `Planck.Agent.clear/1` GenServer call.
- New `Planck.Agent.Session.clear/1` — `DELETE FROM messages` (currently
  only `truncate_after/2` exists at `session.ex:153`; there is no
  clear-all API).
- Resets `state.messages = []` and clears `turn_state` checkpoints.
- Broadcasts a `:cleared` PubSub event so the UI wipes the chat view.
- Trailing text after `/clear` is ignored (`/clear` takes no arguments).

#### `/compact [prompt]`

Forces a compaction pass on demand, regardless of the compactor's own
trigger heuristic. The optional trailing text is threaded into the
compactor as a user-supplied prompt that can steer the summarization.

- New `Planck.Agent.compact/2` GenServer call accepting
  `args :: %{prompt: String.t() | nil}`.
- **Force** — bypasses `compact?/3` (the cheap trigger check) and calls
  `compact/4` directly. The compactor may still return `:skip` if it finds
  nothing worth summarizing.
- **Idle** — runs `apply_compact` with `force: true` and the args,
  persists the resulting summary message, broadcasts `:compacted`, and
  returns to idle. No new user message is enqueued and no LLM stream is
  kicked off — this is a standalone compaction pass, not a turn.
- **Busy** — stores `pending_compact_args` and runs at the next turn
  boundary (see "Queue integration" below).
- Trailing text after `/compact` becomes `args.prompt`.

#### Compactor callback change (breaking — reason for v0.3.0)

The `Planck.Agent.Hooks.Compactor` behaviour's `compact/3` callback
becomes **`compact/4`**:

```elixir
@callback compact(
            state  :: Agent.t(),
            context :: Context.t(),
            recent :: [Message.t()],
            args   :: %{prompt: String.t() | nil}
          ) :: compact_result()
```

`args` is an extensible map (currently a single `:prompt` key) so future
per-call compactor options don't require another arity bump. The dispatch
entry point `Hooks.Compactor.compact/4` (`compactor.ex:156`) gains an
`args:` key in its opts (alongside `on_compacting:` / `on_compacted:`),
forwarded to the callback. `compact?/3` arity is unchanged — manual
`/compact` skips it anyway.

The sidecar RPC dispatch path is updated to pass the extra arg through
`:rpc.call/5`.

**Migration note for custom compactor authors**: any module implementing
`use Planck.Agent.Hooks.Compactor` must add a fourth parameter to
`compact/3`. The simplest migration is `def compact(state, context, recent, _args)`
to preserve existing behavior. This is documented in the v0.3.0 changelog
and reflected in [`specs/compactors.md`](../../../compactors.md).

#### `@delegate_system_prompt` → EEx

The built-in compactor's `@delegate_system_prompt` module attribute
(`planck_agent/lib/planck/agent/hooks/compactor/default.ex:62`) becomes an
EEx template. When `/compact` supplies a prompt, it is injected into the
delegate agent's system prompt so the summarization can be steered ("focus
on the API design discussion", "preserve all file paths", etc.). When no
prompt is given (auto-compaction or `/compact` with no trailing text), the
template renders identically to today's static string.

A shared helper `Planck.Agent.EExRenderer.render(template, bindings)`
evaluates the template safely. The same helper is reused by custom
commands (tier 2). The binding name for the compactor is `prompt`
(`nil` when absent); the template guards with `<%= if prompt do %>` to
emit the injection only when present.

### Tier 2 — Custom commands

Custom commands are plain `.md` files with frontmatter, stored on disk in
the same directory-per-command layout as skills. The markdown body is an
EEx template rendered with the user's trailing arguments before being
enqueued as a message.

#### On-disk layout (mirrors `Planck.Agent.Skill`)

```
.planck/commands/
└── review-checklist/
    ├── COMMAND.md          # required (frontmatter + EEx body)
    └── resources/          # optional — files the agent may reference
```

Scanned from both root (`.planck/commands`) and workspace
(`~/.planck/commands`) directories, exactly as skills are.

#### `COMMAND.md` format

```markdown
---
name: review-checklist
description: Runs the project's review checklist against recent changes.
disable-model-invocation: true
help: "/review-checklist [scope]  — checks files in the given scope"
---

# Review Checklist

You are reviewing: <%= args %>

...rest of instructions...
```

Frontmatter is YAML-style, parsed with `:yamerl` (same path as
`Skill.parse_yaml_fields/2` at `skill.ex:341`). Fields:

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `name` | string | yes | — | Unique command identifier, used in `/name` |
| `description` | string | yes | — | One-line summary shown in the UI dropdown |
| `disable-model-invocation` | boolean | no | `true` | Parsed and stored now; used in the follow-up `run_command` tool step to gate model invocation. Has no effect in step 4 (user-only). |
| `help` | string | no | `nil` | Usage string shown as the dropdown row subtitle (e.g. `/review-checklist [scope]`) |

The body below the frontmatter is an EEx template. The binding `args`
holds the user's trailing text (the string after the command name and
its first space), or `nil` when no trailing text was given.

#### New module `Planck.Agent.Command`

Mirrors `Planck.Agent.Skill` (`skill.ex`):

- `Command.t()` struct: `name`, `description`, `path`, `command_file`,
  `disable_model_invocation` (default `true`), `help`, `template` (the
  raw EEx body string).
- `load_all/1`, `load_dir/1`, `load_entry/2`, `from_file/1` — clone of
  `skill.ex:118-327` with `COMMAND.md` as the sentinel file name.
- Frontmatter parser reusing the `:yamerl` approach.

#### Config + store wiring (mirrors skills)

- New `Config.commands_dirs` (default `[".planck/commands", "~/.planck/commands"]`)
  in `planck_headless/lib/planck/headless/config.ex`, alongside
  `skills_dirs` (line 195). Same `PathList` type, `binding_order: @json`.
- `ResourceStore` (`resource_store.ex:25`) gains a `commands: [Command.t()]`
  field; loaded in `load_resources/0` (line 185) via
  `Command.load_all(Config.commands_dirs!())`.
- `Watcher` (`watcher.ex:91`) watches `commands_dirs`; file changes
  trigger `ResourceStore.reload/0` (existing reload path picks up the new
  commands field automatically once `load_resources/0` populates it).

#### Dispatch + message

When `Headless.prompt/3` matches `/command-name [args]` against
`ResourceStore.get().commands`:

1. Reads the command's `template`.
2. Renders it via `EExRenderer.render(template, args: <trailing text> | nil)`.
3. Enqueues a single `{:custom, :command}` message:
   - `content = [{:text, rendered_body}]`
   - `metadata = %{command: name, args: raw_args, invoked_by: :user}`
4. The message enters the standard prompt/queue path — if the agent is
   idle it triggers a turn immediately; if busy it stacks in
   `state.messages` (detected via `TurnContext.has_pending_input?/2`,
   same as a normal user message).

`Planck.Agent.Message.to_ai_messages/1` (`message.ex:43`) gets a new
clause: `{:custom, :command}` with `metadata.invoked_by == :user` is
mapped to a `:user` AI message so the LLM sees the expanded template
text. The `invoked_by: :assistant` path is stubbed (returns `[]` for now,
matching the "all other custom roles are dropped" default) — it will be
wired in the follow-up `run_command` tool step.

### Tier 3 — Skills (original step-4 behavior, now lowest precedence)

When the name matches a skill in `ResourceStore.get().skills` (the full,
unfiltered store — disabled-invocation skills are reachable here even
though [Step 2](step-2-pool-filtering.md) filters them out of the agent's
autonomous pool), the dispatcher performs the synthetic `load_skill`
tool-call + tool-result injection exactly as the original v0.2.6 step-4
spec described:

1. An assistant message carrying a `tool_calls` entry
   (`load_skill`, `{"name": "skill-name"}`).
2. A `tool`-role message whose content is the skill's `SKILL.md` content,
   prefixed with `"Skill directory: <path>\n\n"` (matching the real
   `load_skill` tool's return format at `skill.ex:236-239`).
3. The user's trailing text (or a minimal placeholder if none) as the
   normal user message after the injection.
4. The `on_skill_use` callback fires (wired in `headless.ex:908-910` to
   `SkillUsage.record_use/5`) so slash-command usage is tracked in
   `.planck/skills.db`.

See the "Injection mechanism" open question below for the Session API
investigation this tier still requires.

### Parser

`Headless.prompt/3` matches `^/([a-z0-9_-]+)(\s+(.*))?$` (case-insensitive
on the name) at the start of the prompt. If the name doesn't match any
tier, the message is passed through verbatim as a normal user message
(no error — the user might genuinely be typing a literal `/path` or
unknown command; the dropdown in [Steps 6-7](step-6-ui-dropdown.md) is
the discovery mechanism, not a hard validation). A message not starting
with `/` is unaffected.

### Where the parsing happens

`Headless.prompt/3` (`headless.ex:169`) is the single chokepoint both the
LiveView prompt path and the HTTP API path (`session_controller.ex:144`)
funnel through. Parsing here keeps the UI dumb and gives external callers
slash-command support for free. The UI layer still needs [Steps 6-7] for
the dropdown, but the *execution* of a typed slash command is not
UI-only.

### Queue integration

The existing implicit message queue (`do_prompt_or_queue` at
`agent.ex:656`, detected via `TurnContext.has_pending_input?/2`) handles
user messages and custom-command/skill injections unchanged — they are
just messages that stack in `state.messages` while the agent is busy.

The two primitives need explicit pending-flags because they are not
messages but GenServer state mutations:

- `Agent.clear` and `Agent.compact` check `state.status`; if not `:idle`,
  they set `pending_clear` / `pending_compact_args` (new fields on
  `Agent.t()`) and broadcast a `:command_queued` PubSub event so the UI
  can show the pending command.
- At the next turn boundary (`do_stream_done` → `maybe_turn_start` at
  `agent.ex:1112`), pending primitives execute **before** any queued
  user message starts a new turn. `pending_clear` wipes the queue (a
  queued user message is deleted along with everything else).
  `pending_compact_args` runs the forced compaction, then the queued
  user message (if any) starts a new turn against the compacted context.

### Out of scope (follow-up step)

**Agent (model) invocation of custom commands.** The
`{:custom, :command}` message's `invoked_by` field is designed to accept
`:assistant` later. A `run_command` tool the model can call (for commands
with `disable-model-invocation: false`) plus the
`disable_model_invocation` filtering on the agent-facing command pool
become a separate step. Step 4 is user-only.

### TDD order

1. **Investigate** `Planck.Agent.Session`'s API for inserting synthetic
   messages (tier 3) and confirm there is no clear-all (tier 1). Decide
   the tier-3 injection mechanism (tool-call simulation vs. system-message
   preamble fallback — see open question).
2. **`Planck.Agent.Command`** — write `command_test.exs` cases for
   `load_all/1`, `from_file/1`, frontmatter parsing (all four fields,
   defaults, malformed values). Mirror the existing `skill_test.exs`
   structure.
3. **`Planck.Agent.EExRenderer`** — write `eex_renderer_test.exs` cases
   for `render/2` with present/absent bindings and unbound-variable
   safety.
4. **`Planck.Agent.Session.clear/1`** — write `session_test.exs` cases
   asserting all messages are deleted and metadata is preserved.
5. **Compactor `compact/4`** — update `compactor_test.exs` (and
   `default_test.exs`) for the new arity; add a case asserting the
   user-supplied `prompt` reaches the delegate system prompt via EEx
   rendering.
6. **`Agent.clear/1` + `Agent.compact/2`** — write `agent_test.exs`
   cases for idle execution, busy queueing, and turn-boundary flush
   ordering (primitives before queued user messages).
7. **`Message.to_ai_messages/1`** — extend `message_test.exs` with the
   `{:custom, :command}` clause.
8. **`Headless.prompt/3` dispatcher** — write `headless_test.exs` cases
   for all three tiers + pass-through (see Test Cases).
9. **HTTP API path** — assert `SessionController` prompt also resolves
   slash commands (parsing is in `Headless.prompt/3`).
10. Run — fail. Implement. Run — pass. `./check planck_agent` and
    `./check planck_headless`.

## Definition of Done

### Tier 1 — primitives

- [ ] `Planck.Agent.clear/1` exists, resets `state.messages` + clears
      `turn_state` checkpoints, calls `Session.clear/1`, broadcasts
      `:cleared`. No LLM call.
- [ ] `Planck.Agent.Session.clear/1` exists (`DELETE FROM messages`).
      Metadata table is preserved. Returns `:ok`.
- [ ] `Planck.Agent.compact/2` exists, accepts `args :: %{prompt: term()}`,
      forces compaction (bypasses `compact?/3`), broadcasts `:compacted`.
- [ ] When idle, `/clear` and `/compact` execute immediately.
- [ ] When busy, both set pending-flags and execute at the next turn
      boundary (in `maybe_turn_start`), before any queued user message.
- [ ] `pending_clear` wipes queued user messages (they are deleted with
      everything else); `pending_compact_args` runs compaction, then the
      queued user message starts a new turn against the compacted context.

### Compactor callback

- [ ] `Planck.Agent.Hooks.Compactor` behaviour's `compact` callback is
      `compact/4` (`state, context, recent, args`).
- [ ] `Hooks.Compactor.compact/5` dispatch (the public entry point) gains
      `args:` in opts, forwarded to the callback.
- [ ] Sidecar RPC path passes the extra arg through `:rpc.call/5`.
- [ ] `compact?/3` arity unchanged.
- [ ] `Planck.Agent.Hooks.Compactor.Default`'s `@delegate_system_prompt`
      is an EEx template; `compact/4` renders it with `prompt:` binding
      (`nil` when absent) via `EExRenderer.render/2`.
- [ ] When `args.prompt` is present, the rendered delegate system prompt
      includes the user's text; when `nil`, it matches today's static
      string byte-for-byte.
- [ ] [`specs/compactors.md`](../../../compactors.md) updated to document
      the `compact/4` signature and the migration note.

### Tier 2 — custom commands

- [ ] `Planck.Agent.Command` module exists with `Command.t()` struct,
      `load_all/1`, `load_dir/1`, `load_entry/2`, `from_file/1`, and a
      `:yamerl`-based frontmatter parser.
- [ ] `COMMAND.md` is the sentinel file name; `name` and `description`
      are required; `disable-model-invocation` defaults to `true`;
      `help` defaults to `nil`.
- [ ] `Planck.Agent.EExRenderer.render/2` exists and is used by both the
      compactor delegate prompt and custom command bodies.
- [ ] `Planck.Headless.Config` declares `commands_dirs` (default
      `[".planck/commands", "~/.planck/commands"]`), `PathList` type.
- [ ] `ResourceStore` has a `commands: [Command.t()]` field, populated in
      `load_resources/0`.
- [ ] `Watcher` watches `commands_dirs`; reload triggers
      `ResourceStore.reload/0`.
- [ ] `Headless.prompt/3` resolves `/command-name [args]` against
      `ResourceStore.get().commands`, renders the EEx body with
      `args: <trailing text> | nil`, enqueues a `{:custom, :command}`
      message with `metadata = %{command: name, args: raw_args,
      invoked_by: :user}`.
- [ ] `Planck.Agent.Message.to_ai_messages/1` maps
      `{:custom, :command}` with `invoked_by: :user` to a `:user` AI
      message; `invoked_by: :assistant` returns `[]` (stub for follow-up).

### Tier 3 — skills

- [ ] `/skill-name [extra]` injects a synthetic `load_skill` tool-call
      (assistant message with `tool_calls`) + tool-result (`tool`-role
      message with the skill content, prefixed with
      `"Skill directory: <path>\n\n"`) before the user's message — *or*,
      if the Session API doesn't support it, a documented system-message
      preamble fallback is used and noted here.
- [ ] The user's trailing text (or a minimal placeholder) is passed as
      the normal user message after the injection.
- [ ] The `on_skill_use` callback fires for the synthetic load, so
      slash-command usage is tracked in `.planck/skills.db`.
- [ ] Disabled-invocation skills are loadable by name (read from the full
      `ResourceStore.skills`, not the agent's filtered pool).

### Dispatcher + pass-through

- [ ] `Headless.prompt/3` parses a leading `/<command-name>` (with
      optional trailing text) and dispatches by tier precedence:
      built-ins → custom commands → skills.
- [ ] A `/<name>` where `name` matches no tier is passed through verbatim
      as a normal user message (no error, no injection).
- [ ] A message not starting with `/` is unaffected — passed through
      verbatim.
- [ ] Name collision: a built-in shadows a custom command shadows a skill
      (tier 1 wins over 2 wins over 3).
- [ ] Both the LiveView prompt path and the HTTP API prompt path
      (`session_controller.ex:144`) resolve slash commands (because
      parsing lives in `Headless.prompt/3`).

### Checks

- [ ] `mix test` in `planck_agent` and `planck_headless` passes.
- [ ] `./check planck_agent` and `./check planck_headless` pass.

## Use Cases

```gherkin
Feature: Slash command dispatcher resolves three tiers

  Background:
    Given ResourceStore is loaded with:
      | kind    | name             | disable_model_invocation |
      | skill   | grill-me         | true                     |
      | skill   | elixir-style     | false                    |
      | command | review-checklist | true                     |
    And the agent is idle

  # Tier 1 — /clear

  Scenario: /clear wipes the session
    Given the session has 5 messages including a {:custom, :summary} checkpoint
    When the user submits "/clear"
    Then Session.clear/1 is called
    And state.messages is []
    And turn_state checkpoints are cleared
    And a :cleared PubSub event is broadcast
    And no LLM call is made
    And session metadata (id, team_id, name) is preserved

  Scenario: /clear ignores trailing text
    When the user submits "/clear everything please"
    Then the session is cleared
    And the trailing text "everything please" is ignored

  Scenario: /clear while busy queues and flushes at the turn boundary
    Given the agent is streaming a turn
    When the user submits "/clear"
    Then pending_clear is set
    And a :command_queued event is broadcast
    When the current turn ends (do_stream_done → maybe_turn_start)
    Then pending_clear executes before any queued user message
    And any user message queued during the busy turn is deleted

  # Tier 1 — /compact

  Scenario: /compact with a prompt forces compaction
    Given the agent is idle and context is below the 0.8 threshold
    # compact?/3 would return false, but /compact forces
    When the user submits "/compact focus on the API design discussion"
    Then Agent.compact/2 is called with args %{prompt: "focus on the API design discussion"}
    And compact?/3 is NOT called (bypassed)
    And compact/4 is called with args %{prompt: "focus on the API design discussion"}
    And the delegate system prompt is EEx-rendered with the user's prompt injected
    And a :compacted PubSub event is broadcast
    And no new user message is enqueued
    And no LLM stream is kicked off for a turn

  Scenario: /compact with no prompt renders the default delegate prompt
    When the user submits "/compact"
    Then Agent.compact/2 is called with args %{prompt: nil}
    And the rendered delegate system prompt matches today's static string byte-for-byte

  Scenario: /compact while busy queues and runs before the next turn
    Given the agent is streaming a turn
    When the user submits "/compact preserve all file paths"
    Then pending_compact_args is set to %{prompt: "preserve all file paths"}
    When the current turn ends
    Then the forced compaction runs before any queued user message starts a new turn
    And the queued user message (if any) starts a new turn against the compacted context

  Scenario: /compact may still return :skip
    Given the compactor's compact/4 finds nothing old enough to summarize
    When the user submits "/compact"
    Then compact/4 returns :skip
    And no summary message is persisted
    And the session is unchanged
    And a :compacted event is NOT broadcast (nothing happened)

  # Tier 2 — custom commands

  Scenario: Custom command with arguments
    When the user submits "/review-checklist src/auth"
    Then the COMMAND.md template is rendered with args: "src/auth"
    And a {:custom, :command} message is enqueued with:
      | content  | [{:text, "<rendered body>"}]                                   |
      | metadata | %{command: "review-checklist", args: "src/auth", invoked_by: :user} |
    And the agent processes the message with the rendered body as a :user AI message

  Scenario: Custom command with no arguments
    When the user submits "/review-checklist"
    Then the template is rendered with args: nil
    And a {:custom, :command} message is enqueued with args: nil in metadata

  Scenario: Custom command while busy queues as a normal message
    Given the agent is streaming a turn
    When the user submits "/review-checklist src/auth"
    Then the {:custom, :command} message stacks in state.messages
    And TurnContext.has_pending_input?/2 detects it after the turn ends
    And a new turn starts with the rendered body

  # Tier 3 — skills

  Scenario: Slash command loads a skill via synthetic tool-call simulation
    When the user submits "/grill-me give me five questions"
    Then the session conversation contains, in order:
      | role      | content                                          |
      | assistant | tool_calls: [load_skill {"name": "grill-me"}]   |
      | tool      | "Skill directory: <path>\n\n<SKILL.md content>" |
      | user      | "give me five questions"                        |
    And the agent processes the user message with the skill content in context

  Scenario: Disabled-invocation skill is loadable via slash command
    Given "grill-me" has disable_model_invocation: true
    When the user submits "/grill-me"
    Then the synthetic load_skill succeeds (read from full ResourceStore.skills)
    And the agent receives the skill content

  Scenario: Slash-command skill usage is recorded in SkillUsage
    When the user submits "/grill-me"
    Then SkillUsage.record_use/5 is called for "grill-me"
    And a row exists in .planck/skills.db for this session/agent/skill

  # Precedence + pass-through

  Scenario: Built-in shadows a custom command of the same name
    Given a custom command named "clear" exists in ResourceStore.commands
    When the user submits "/clear"
    Then Agent.clear/1 is called (tier 1 wins)
    And the custom command is NOT invoked

  Scenario: Custom command shadows a skill of the same name
    Given a skill named "review-checklist" also exists
    When the user submits "/review-checklist"
    Then the custom command is invoked (tier 2 wins)
    And the skill is NOT loaded

  Scenario: Unknown slash command passes through
    When the user submits "/not-a-command hello there"
    Then no tier matches
    And the user message is "/not-a-command hello there" verbatim

  Scenario: Non-slash message is unaffected
    When the user submits "hello there"
    Then no tier matches
    And the user message is "hello there" verbatim

  Scenario: HTTP API path also resolves slash commands
    Given an external script POSTs to /api/sessions/:id/prompt with body
      "/compact summarize the debugging steps"
    Then Agent.compact/2 is called with the parsed prompt
    # because parsing is in Headless.prompt/3, not the LiveView
```

## Test Cases

In `planck_agent/test/planck/agent/command_test.exs` (new file):

- `describe "Command.load_all/1"`:
  - loads commands from multiple directories (root + workspace)
  - skips directories without `COMMAND.md`
  - skips malformed frontmatter (logs a warning)
- `describe "Command.from_file/1"`:
  - parses all four frontmatter fields
  - `disable-model-invocation` defaults to `true` when absent
  - `help` defaults to `nil` when absent
  - non-boolean `disable-model-invocation` normalizes to `true` (the
    default — only literal `false` disables the flag)
  - body (EEx template) is stored raw, not rendered at load time
- `describe "COMMAND.md sentinel"`:
  - a directory with `SKILL.md` but no `COMMAND.md` is not loaded as a
    command (no collision with skills)

In `planck_agent/test/planck/agent/eex_renderer_test.exs` (new file):

- `describe "EExRenderer.render/2"`:
  - renders a template with present bindings
  - renders a template with `nil` bindings (the `<%= if x do %>` guard
    emits nothing)
  - raises a clear error on truly unbound variables (not silently empty)

In `planck_agent/test/planck/agent/session_test.exs`:

- `describe "Session.clear/1"`:
  - deletes all message rows
  - preserves the `metadata` table
  - subsequent `append/3` starts from row id 1 again (AUTOINCREMENT reset)

In `planck_agent/test/planck/agent/hooks/compactor_test.exs` (and
`default_test.exs`):

- `describe "compact/4 arity"`:
  - the callback receives the `args` map as its 4th parameter
  - `compact?/3` arity is unchanged
- `describe "compact/4 with prompt"`:
  - when `args.prompt` is a string, the delegate system prompt includes it
  - when `args.prompt` is `nil`, the delegate prompt matches the
    pre-v0.3.0 static string byte-for-byte
- `describe "dispatch"`:
  - `Hooks.Compactor.compact/5` forwards `args:` to the callback
  - sidecar RPC path passes the extra arg

In `planck_agent/test/planck/agent/agent_test.exs`:

- `describe "Agent.clear/1"`:
  - idle: wipes messages, clears checkpoints, broadcasts `:cleared`
  - busy: sets `pending_clear`, broadcasts `:command_queued`
  - turn boundary: `pending_clear` executes before queued user messages
- `describe "Agent.compact/2"`:
  - idle: forces compaction (bypasses `compact?/3`), broadcasts `:compacted`
  - idle with `:skip` result: no broadcast, no state change
  - busy: sets `pending_compact_args`
  - turn boundary: runs before the queued user message's new turn
- `describe "slash command dispatch (tiers)"`:
  - `/clear` → `Agent.clear`
  - `/compact foo` → `Agent.compact` with `%{prompt: "foo"}`
  - `/review-checklist src` → `{:custom, :command}` message enqueued
  - `/grill-me extra` → synthetic `load_skill` injection
  - `/unknown` → verbatim pass-through
  - built-in shadows same-named custom command
  - custom command shadows same-named skill

In `planck_agent/test/planck/agent/message_test.exs`:

- `describe "to_ai_messages {:custom, :command}"`:
  - `invoked_by: :user` → `[%Planck.AI.Message{role: :user, ...}]`
  - `invoked_by: :assistant` → `[]` (stub)

In `planck_headless/test/planck/headless_test.exs`:

- `describe "Headless.prompt/3 slash command dispatch"`:
  - resolves `/clear` and `/compact` against built-ins
  - resolves `/command-name` against `ResourceStore.commands`
  - resolves `/skill-name` against `ResourceStore.skills` (full store)
  - passes non-slash messages through unchanged
  - passes unknown `/<name>` through verbatim
- `describe "hot reload updates commands"`:
  - after `ResourceStore.reload/0` with a newly-added command, the
    dispatcher resolves it (`async: false` — touches global store)

In `planck_cli/test/.../session_controller_test.exs` (if HTTP API tests
exist there):

- `describe "POST /api/sessions/:id/prompt with slash command"`:
  - `/clear` via HTTP clears the session
  - `/compact foo` via HTTP forces compaction with the prompt

## Open question (must resolve during TDD pre-work)

**Session insertion API for tier 3 (skill injection).** Before writing
the skill-tier tests, read `planck_agent/lib/planck/agent/session.ex` and
find (or determine the absence of) an API for inserting arbitrary message
entries (assistant + tool pair). If absent, document the
system-message-preamble fallback in this file's Definition of Done (tier
3 section) and proceed with that. The fallback is acceptable for v0.3.0;
tool-call simulation can be revisited when `Session` grows the API.

This open question does **not** affect tiers 1 or 2 — `/clear` uses the
new `Session.clear/1`, and custom commands use the standard
`Session.append/3` path that every user message already uses.

## Files touched

| File | Change |
|---|---|
| `planck_agent/lib/planck/agent.ex` | `Agent.clear/1`, `Agent.compact/2`, `pending_clear`/`pending_compact_args` fields on `Agent.t()`, turn-boundary execution in `maybe_turn_start` |
| `planck_agent/lib/planck/agent/session.ex` | `Session.clear/1` (`DELETE FROM messages`) |
| `planck_agent/lib/planck/agent/hooks/compactor.ex` | `compact/4` callback; `compact/5` dispatch passes `args:`; sidecar RPC path updated; `compact_opts` gains `args:` key |
| `planck_agent/lib/planck/agent/hooks/compactor/default.ex` | `@delegate_system_prompt` → EEx template; `compact/4` renders via `EExRenderer` |
| `planck_agent/lib/planck/agent/command.ex` | **new** — `Command.t()`, `load_all/1`, `from_file/1`, frontmatter parser |
| `planck_agent/lib/planck/agent/eex_renderer.ex` | **new** — shared `render/2` helper |
| `planck_agent/lib/planck/agent/message.ex` | `{:custom, :command}` clause in `to_ai_messages/1` |
| `planck_headless/lib/planck/headless.ex` | command dispatcher in `prompt/3` (parse + tier resolution) |
| `planck_headless/lib/planck/headless/config.ex` | `commands_dirs` config (default `[".planck/commands", "~/.planck/commands"]`) |
| `planck_headless/lib/planck/headless/resource_store.ex` | `commands: [Command.t()]` field + `Command.load_all` in `load_resources/0` |
| `planck_headless/lib/planck/headless/watcher.ex` | watch `commands_dirs` |
| `specs/compactors.md` | update `compact/4` signature + migration note |
