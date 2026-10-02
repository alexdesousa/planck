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
| 2. Custom commands | `ResourceStore.get().commands` by name | Enqueue a `{:custom, :command}` message via `Agent.command/3` with an EEx-rendered body |
| 3. Skills | `ResourceStore.get().skills` by name (full, unfiltered) | `Agent.load_skill/3` enqueues a `{:custom, :skill}` message (skill content as a `:user` AI message), then the user's text if non-empty |
| — | No match | Pass the message through verbatim as a normal user message |

Because parsing lives in `Headless.prompt/3` (the single chokepoint both
the LiveView and the HTTP API `SessionController.prompt` at
`session_controller.ex:144` funnel through), all three tiers are available
to both paths for free.

This step supersedes the original v0.2.6 step-4 design (which only handled
skill loading). The skill-loading tier (3) replaces the old
`inject_tool_result` + `prompt` pair with a dedicated `Agent.load_skill/3`
call and a `{:custom, :skill}` message; tiers 1 and 2 are new.

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
- **Idle** — replies `:ok` immediately and defers the actual compaction to
  `handle_continue({:compact, args})`, which runs `apply_compact` with
  `force: true` and the args, persists the resulting summary message,
  broadcasts `:compacted`, then re-enters `maybe_turn_start` to check for
  queued input. The immediate reply means the caller's `GenServer.call`
  doesn't timeout during the delegate summarisation (which can take tens
  of seconds). No new user message is enqueued — this is a standalone
  compaction pass, not a turn.
- **Busy** — enqueues a `{:custom, :compact}` message (see "Queue
  integration" below) and runs at the next turn boundary.
- Trailing text after `/compact` becomes `args.prompt`.
- `apply_compact(state, opts \\ [])` defaults `:args` to `%{prompt: nil}`
  via `Keyword.put_new`, and injects the `:compacting`/`:compacted`
  broadcast callbacks internally so callers only pass `args:`/`force:`.

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

#### Dispatch — `Agent.command/3` (new)

When `Headless.prompt/3` matches `/command-name [args]` against
`ResourceStore.get().commands`:

1. Reads the command's `template`.
2. Renders it via `EExRenderer.render(template, args: <trailing text> | nil)`.
3. Builds `command_meta = %{command: name, args: raw_args, invoked_by: :user}`.
4. Calls the new `Agent.command(pid, command_meta, rendered_body)`.

`Agent.command/3` is a new public GenServer call (see "New APIs" below)
that enqueues a `{:custom, :command}` message — *not* a regular user
message. The message:

- `role = {:custom, :command}`
- `content = [{:text, rendered_body}]`
- `metadata = command_meta`

If the agent is idle, `Agent.command/3` triggers a turn immediately (same
as a normal prompt). If busy, the message stacks in `state.messages` and
is detected via `TurnContext.has_pending_input?/2` at the next turn
boundary.

This replaces the previous design, which overloaded `Agent.prompt/3`
with a `:command` keyword option. The `:command` opt on `Agent.prompt/3`
is **removed** — `Agent.prompt/3` reverts to pure user-message handling,
and all command dispatch goes through the dedicated `Agent.command/3`.

`Planck.Agent.Message.to_ai_messages/1` (`message.ex:43`) gets a new
clause: `{:custom, :command}` with `metadata.invoked_by == :user` is
mapped to a `:user` AI message so the LLM sees the expanded template
text. The `invoked_by: :assistant` path is stubbed (returns `[]` for now,
matching the "all other custom roles are dropped" default) — it will be
wired in the follow-up `run_command` tool step.

### Tier 3 — Skills (lowest precedence)

When the name matches a skill in `ResourceStore.get().skills` (the full,
unfiltered store — disabled-invocation skills are reachable here even
though [Step 2](step-2-pool-filtering.md) filters them out of the agent's
autonomous pool), the dispatcher calls `Agent.load_skill/3`:

1. The agent reads the skill's `SKILL.md` and builds
   `skill_content = "Skill directory: #{skill.path}\n\n" <> content`.
2. A `{:custom, :skill}` message is enqueued with
   `metadata = %{skill: Skill.t(), skill_content: skill_content}`.
3. If the user supplied trailing text, a `:user` message with that text
   is enqueued after the skill message. If not, no user message is added
   — the `{:custom, :skill}` message alone drives the next turn
   (`TurnContext.has_pending_input?/2` treats `{:custom, :skill}` as
   pending input).
4. `Message.to_ai_messages/1` converts `{:custom, :skill}` to a `:user`
   AI message containing the `skill_content` text, so the LLM sees the
   loaded SKILL.md.

User-initiated skill loading does **not** record usage — only the
autonomous `load_skill` *tool* path (called by the LLM) records via the
`on_skill_use` callback. The previous `inject_tool_result`-based
injection is replaced; `inject_tool_result/3` is retained for the
sidecar `SkillReflector` path only.

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

### Queue integration — unified command queue

The previous design held queued `/clear` and `/compact` in a separate
`Planck.Agent.PendingCommands` struct (`pending_clear` /
`pending_compact_args` fields on `Agent.t()`). **This struct is removed.**
All queued operations now live as unpersisted messages in
`state.messages`, the same list that already holds queued user messages
and queued command messages while the agent is busy:

| Queued operation | Message role | content | metadata |
|---|---|---|---|
| User message | `:user` | normalized content | — |
| Custom command | `{:custom, :command}` | rendered body | `command_meta` |
| `/clear` primitive | `{:custom, :clear}` | `[]` | — |
| `/compact` primitive | `{:custom, :compact}` | `[]` | `%{prompt: args}` |

`Planck.Agent.Message.to_ai_messages/1` already drops unknown
`{:custom, _}` roles (the catch-all at `message.ex:61`), so `:clear` /
`:compact` markers never reach the LLM — no new filter is required.

#### Turn-boundary drain

At the next turn boundary (`do_stream_done` → `maybe_turn_start`),
`drain_control_markers/1` scans `state.messages` for control markers and
returns one of:

- `{:clear, cleared_state}` — a `:clear` marker was found; `clear_state`
  has already wiped all messages (queued user/command messages deleted
  along with everything else; the markers go with them).
- `{:compact, state_with_markers_stripped, args}` — a `:compact` marker
  was found (the **last** one wins, matching the previous struct-overwrite
  semantics); markers are stripped from `state.messages` and the compact
  args are returned. Compaction is **not** run here — it is deferred to
  `handle_continue({:compact, args})` so the caller doesn't block.
- `{:none, state}` — no control markers.

`maybe_turn_start` matches on this return. For `:clear`, it returns the
cleared state. For `:compact`, it returns
`{:noreply, state, {:continue, {:compact, args}}}` — compaction runs in
`handle_continue`, which calls `apply_compact` and then re-enters
`maybe_turn_start` (iteration via `handle_continue`, not recursion) to
check for queued input. For `:none`, it delegates to `start_queued_turn/1`.

The shared `start_queued_turn/1` helper — the `has_pending_input?` check +
turn kick-off — is used by both `maybe_turn_start` and `do_abort/1`.

#### Busy-path enqueue

`Agent.clear/1` and `Agent.compact/2` check `state.status`; if not
`:idle`, they append the marker message and broadcast a `:message_queued`
PubSub event (the same event the UI already handles for queued user
messages) carrying `role` so the UI can render the chip distinctly:

```elixir
# /clear busy path
msg = Message.new({:custom, :clear}, [])
broadcast(state, :message_queued, %{id: msg.id, content: [], role: :clear})

# /compact busy path
msg = Message.new({:custom, :compact}, [], %{prompt: args})
broadcast(state, :message_queued, %{id: msg.id, content: [], role: :compact, args: args})
```

This replaces the previous `:command_queued` event. The UI rendering of
these queued chips is [Step 8](step-8-command-rendering.md).

#### `Agent.abort/1` flush

`handle_call(:abort, ...)` delegates to `do_abort/1`, which cancels the
active stream (`cancel_stream/1`) and running tools
(`cancel_running_tools/1`), resets streaming state, then runs the same
`drain_control_markers` → `start_queued_turn` pipeline as
`maybe_turn_start` (via a `with` that matches `:none` → `start_queued_turn`,
`:clear` → cleared state, `:compact` → `{:continue, {:compact, args}}`).
This keeps the abort-path semantics identical to the turn-boundary path.

### New APIs

#### `Agent.command/3`

```elixir
@spec command(agent(), map(), String.t() | [Planck.AI.Message.content_part()]) ::
        :ok | {:error, :already_sent}
def command(agent, command_meta, content) do
  GenServer.call(agent, {:command, command_meta, content})
end
```

`handle_call({:command, command_meta, content}, ...)` delegates to the
existing `do_prompt_or_queue_command` / `do_prompt_command` bodies
(unchanged logic — just a new entry point). Idle → triggers a turn;
busy → stacks in `state.messages` and broadcasts `:message_queued`
with `role: :command` and `command_meta`.

#### `Agent.cancel_queued/2`

```elixir
@spec cancel_queued(agent(), String.t()) ::
        :ok | {:error, :not_found} | {:error, :already_sent}
def cancel_queued(agent, id) do
  GenServer.call(agent, {:cancel_queued, id})
end
```

Removes the message with the matching `id` from `state.messages`, but
**only if still unpersisted** (the `id` is the agent's own string id,
not a db id). Once the message has been flushed to the session (a real
db id), it can't be cancelled — `{:error, :already_sent}`. Returns
`{:error, :not_found}` if no message with that id is in the list.

Uniformly covers queued user messages, custom-command messages, and
`:clear` / `:compact` markers — a capability gain over the previous
design, where a queued `/clear` couldn't be cancelled at all. The UI
delete button is wired in [Step 8](step-8-command-rendering.md).

No broadcast on cancel — the UI removes its own pending entry on `:ok`.

### Rewind interaction (behavioral change)

`Agent.rewind_to_message/2` (`agent.ex:629`) calls
`reload_messages_from_session` which rebuilds `state.messages` from the
DB. Because `:clear` / `:compact` markers are now unpersisted entries in
that list (rather than a separate surviving field), a rewind silently
drops them. This is the intended new behavior — rewinding to inspect
history shouldn't trigger a pending wipe — and is a deliberate change
from v0.2.x (see "Behavioral changes" in the top-level spec).

### Out of scope (follow-up step)

**Agent (model) invocation of custom commands.** The
`{:custom, :command}` message's `invoked_by` field is designed to accept
`:assistant` later. A `run_command` tool the model can call (for commands
with `disable-model-invocation: false`) plus the
`disable_model_invocation` filtering on the agent-facing command pool
become a separate step. Step 4 is user-only.

### TDD order

1. **Investigate** `Planck.Agent.Session`'s API to confirm there is no
   clear-all (tier 1) — `Session.clear/1` needs to be added.
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
   cases for idle execution, busy queueing (now as `{:custom, :clear}` /
   `{:custom, :compact}` messages, not pending-flags), and
   turn-boundary flush ordering via `drain_control_markers` (primitives
   before queued user messages).
7. **`Agent.command/3`** — write `agent_test.exs` cases for idle
   (triggers turn, persists `{:custom, :command}`) and busy (stacks in
   `state.messages`, broadcasts `:message_queued` with `role: :command`).
8. **`Agent.cancel_queued/2`** — write `agent_test.exs` cases covering
   all four marker kinds (user, command, clear, compact), the
   `:already_sent` rejection for a flushed/persisted message, and
   `:not_found` for an absent id.
9. **`Agent.prompt/3` `:command` opt removal** — update existing tests
   that relied on the opt; assert `Agent.prompt/3` no longer accepts a
   `:command` keyword (command dispatch is via `Agent.command/3`).
10. **`Message.to_ai_messages/1`** — extend `message_test.exs` with the
    `{:custom, :command}` clause; confirm `{:custom, :clear}` /
    `{:custom, :compact}` are dropped by the existing catch-all.
11. **`Headless.prompt/3` dispatcher** — write `headless_test.exs` cases
    for all three tiers + pass-through (see Test Cases); assert tier 2
    calls `Agent.command/3` (not `Agent.prompt/3` with an opt).
12. **HTTP API path** — assert `SessionController` prompt also resolves
    slash commands (parsing is in `Headless.prompt/3`).
13. Run — fail. Implement. Run — pass. `./check planck_agent` and
    `./check planck_headless`.

## Definition of Done

### Tier 1 — primitives

- [ ] `Planck.Agent.clear/1` exists, resets `state.messages` + clears
      `turn_state` checkpoints, calls `Session.clear/1`, broadcasts
      `:cleared`. No LLM call.
- [ ] `Planck.Agent.Session.clear/1` exists (`DELETE FROM messages`).
      Metadata table is preserved. Returns `:ok`.
- [ ] `Planck.Agent.compact/2` exists, accepts `args :: %{prompt: term()}`,
      replies `:ok` immediately and defers compaction to
      `handle_continue({:compact, args})` (bypasses `compact?/3`,
      broadcasts `:compacted`).
- [ ] When idle, `/clear` executes immediately; `/compact` replies
      immediately and runs via `handle_continue`.
- [ ] When busy, both enqueue a `{:custom, :clear}` / `{:custom, :compact}`
      message in `state.messages` (no separate pending-flags) and
      broadcast `:message_queued` with `role: :clear` / `:compact`.
- [ ] `PendingCommands` struct + `pending_commands` field on `Agent.t()`
      are **removed**.
- [ ] `maybe_turn_start` drains control markers (clear > compact >
      input) from the unified list via `drain_control_markers/1`
      before checking `TurnContext.has_pending_input?/2`.
- [ ] `drain_control_markers` clears the queue when a `:clear` marker is
      present; strips `:compact` markers (last wins) and returns args for
      deferral via `handle_continue({:compact, args})` — does not run
      compaction inline.
- [ ] `do_abort/1` cancels stream + tools, resets streaming, then runs
      the same `drain_control_markers` → `start_queued_turn` pipeline as
      `maybe_turn_start`.
- [ ] `start_queued_turn/1` is shared by `maybe_turn_start` and `do_abort`.
- [ ] Rewind (`rewind_to_message/2`) silently drops unpersisted `:clear`
      / `:compact` markers (reload from DB) — documented behavior change.

### Compactor callback

- [ ] `Planck.Agent.Hooks.Compactor` behaviour's `compact` callback is
      `compact/4` (`state, context, recent, args`).
- [ ] `Hooks.Compactor.compact/4` dispatch (the public entry point) gains
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
      `args: <trailing text> | nil`, and calls `Agent.command/3` with
      `command_meta = %{command: name, args: raw_args, invoked_by: :user}`
      and the rendered body.
- [ ] `Planck.Agent.Message.to_ai_messages/1` maps
      `{:custom, :command}` with `invoked_by: :user` to a `:user` AI
      message; `invoked_by: :assistant` returns `[]` (stub for follow-up).

### New APIs

- [ ] `Planck.Agent.command/3` exists, enqueues a `{:custom, :command}`
      message; idle triggers a turn, busy stacks in `state.messages` and
      broadcasts `:message_queued` with `role: :command` + `command_meta`.
- [ ] `handle_call({:command, ...})` delegates to
      `do_prompt_or_queue_command` / `do_prompt_command`.
- [ ] `Planck.Agent.cancel_queued/2` exists; removes an unpersisted
      message by string id from `state.messages`; returns `:ok`,
      `{:error, :not_found}`, or `{:error, :already_sent}` for a
      flushed/persisted message. No broadcast on cancel.
- [ ] `Agent.cancel_queued/2` covers all four marker kinds (user,
      command, clear, compact) uniformly.
- [ ] The `:command` keyword opt is **removed** from
      `Agent.prompt/3`'s `handle_call({:prompt, ...})` — `Agent.prompt/3`
      is purely user-message handling.

### Tier 3 — skills

- [ ] `Agent.load_skill/3` exists; reads the skill's `SKILL.md`, enqueues
      a `{:custom, :skill}` message with `metadata = %{skill: Skill.t(),
      skill_content: ...}`, then a `:user` message if trailing text was
      provided (no placeholder when absent).
- [ ] `TurnContext.has_pending_input?/2` treats `{:custom, :skill}` as
      pending input so a skill-only load still triggers a turn.
- [ ] `Message.to_ai_messages/1` maps `{:custom, :skill}` to a `:user` AI
      message containing the `skill_content` text.
- [ ] User-initiated skill loading does **not** record usage (only the
      autonomous `load_skill` tool records via `on_skill_use`).
- [ ] `inject_tool_result/3` is retained for the sidecar `SkillReflector`;
      only the Tier-3 user slash-command path moved to `Agent.load_skill/3`.
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

  Scenario: /clear while busy enqueues a marker and flushes at the turn boundary
    Given the agent is streaming a turn
    When the user submits "/clear"
    Then a {:custom, :clear} message is appended to state.messages
    And a :message_queued event is broadcast with role: :clear
    And no separate pending_clear field exists (PendingCommands removed)
    When the current turn ends (do_stream_done → maybe_turn_start)
    Then drain_control_markers runs the :clear before any queued user message
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

  Scenario: /compact while busy enqueues a marker and runs before the next turn
    Given the agent is streaming a turn
    When the user submits "/compact preserve all file paths"
    Then a {:custom, :compact} message is appended to state.messages with metadata %{prompt: "preserve all file paths"}
    And a :message_queued event is broadcast with role: :compact
    When the current turn ends
    Then drain_control_markers runs the forced compaction (last marker wins) before any queued user message starts a new turn
    And the queued user message (if any) starts a new turn against the compacted context

  Scenario: Multiple queued /compact markers — last one wins
    Given the agent is streaming a turn
    When the user submits "/compact focus on auth"
    And then submits "/compact focus on the UI"
    Then state.messages has two {:custom, :compact} markers
    When the current turn ends
    Then drain_control_markers runs compaction with prompt "focus on the UI" (last wins)
    And only one compaction pass runs

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
    And Agent.command/3 is called with command_meta %{command: "review-checklist", args: "src/auth", invoked_by: :user}
    And a {:custom, :command} message is enqueued with:
      | content  | [{:text, "<rendered body>"}]                                   |
      | metadata | %{command: "review-checklist", args: "src/auth", invoked_by: :user} |
    And the agent processes the message with the rendered body as a :user AI message

  Scenario: Custom command with no arguments
    When the user submits "/review-checklist"
    Then the template is rendered with args: nil
    And Agent.command/3 is called with args: nil in command_meta

  Scenario: Custom command while busy stacks as a message
    Given the agent is streaming a turn
    When the user submits "/review-checklist src/auth"
    Then the {:custom, :command} message stacks in state.messages
    And a :message_queued event is broadcast with role: :command
    And TurnContext.has_pending_input?/2 detects it after the turn ends
    And a new turn starts with the rendered body

  Scenario: Cancel a queued custom command
    Given a {:custom, :command} message is queued (unpersisted, string id)
    When the UI calls Agent.cancel_queued/2 with that id
    Then the message is removed from state.messages
    And :ok is returned
    And no broadcast is sent (the UI removes its own entry)

  Scenario: Cancel a queued /clear
    Given a {:custom, :clear} message is queued
    When the UI calls Agent.cancel_queued/2 with that id
    Then the :clear marker is removed from state.messages
    And :ok is returned
    # previously impossible — PendingCommands had no cancel path

  Scenario: Cancel a flushed message fails
    Given a queued message has been flushed to the session (now has a db id)
    When the UI calls Agent.cancel_queued/2 with the old string id
    Then {:error, :already_sent} is returned
    And state.messages is unchanged

  Scenario: Cancel an unknown id fails
    When the UI calls Agent.cancel_queued/2 with a nonexistent id
    Then {:error, :not_found} is returned

  Scenario: Rewind drops queued primitives
    Given a {:custom, :clear} message is queued while the agent is busy
    When the user rewinds to an earlier message (rewind_to_message/2)
    Then state.messages is reloaded from the DB
    And the {:custom, :clear} marker is gone (unpersisted, not in the DB)
    And no clear runs (the pending wipe is abandoned — intended behavior change)

  # Tier 3 — skills

  Scenario: Slash command loads a skill via Agent.load_skill/3
    When the user submits "/grill-me give me five questions"
    Then Agent.load_skill/3 is called with the grill-me skill and "give me five questions"
    And a {:custom, :skill} message is enqueued with skill_content in metadata
    And a :user message with "give me five questions" is enqueued after it
    And the LLM sees the skill content as a :user AI message (via to_ai_messages/1)

  Scenario: Skill with no trailing text
    When the user submits "/grill-me"
    Then Agent.load_skill/3 is called with nil user_text
    And only a {:custom, :skill} message is enqueued (no :user message)
    And a turn starts because has_pending_input?/2 detects {:custom, :skill}

  Scenario: Disabled-invocation skill is loadable via slash command
    Given "grill-me" has disable_model_invocation: true
    When the user submits "/grill-me"
    Then Agent.load_skill/3 succeeds (read from full ResourceStore.skills)
    And the agent receives the skill content

  Scenario: User-initiated skill loading does not record usage
    When the user submits "/grill-me"
    Then SkillUsage.record_use/5 is NOT called
    And no row is added to .planck/skills.db for this load
    # only the autonomous load_skill tool records usage via on_skill_use

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
  - `Hooks.Compactor.compact/4` forwards `args:` to the callback
  - sidecar RPC path passes the extra arg

In `planck_agent/test/planck/agent/agent_test.exs`:

- `describe "Agent.clear/1"`:
  - idle: wipes messages, clears checkpoints, broadcasts `:cleared`
  - busy: appends `{:custom, :clear}` to `state.messages`, broadcasts
    `:message_queued` with `role: :clear` (no separate pending field)
  - turn boundary: `drain_control_markers` runs `:clear` before queued
    user messages; queued messages are deleted
- `describe "Agent.compact/2"`:
  - idle: replies `:ok` immediately, defers to `handle_continue({:compact, args})`
  - idle with `:skip` result: no broadcast, no state change
  - busy: appends `{:custom, :compact}` to `state.messages` with
    `%{prompt: args}` metadata, broadcasts `:message_queued` with
    `role: :compact`
  - turn boundary: deferred via `handle_continue`, runs before queued input
  - multiple queued compacts: last marker's prompt wins
- `describe "Agent.command/3"`:
  - idle: persists `{:custom, :command}`, triggers a turn
  - busy: stacks in `state.messages`, broadcasts `:message_queued` with
    `role: :command` + `command_meta`
- `describe "Agent.load_skill/3"`:
  - idle with user text: persists `{:custom, :skill}` + `:user`, triggers turn
  - idle with nil/empty text: persists only `{:custom, :skill}`, triggers turn
  - busy: stacks skill (+ user if provided), broadcasts `:message_queued`
  - file read error with user text: falls through to `do_prompt_or_queue`
  - file read error with nil: returns `:ok` with no state change
- `describe "Agent.cancel_queued/2"`:
  - removes a queued user message by string id → `:ok`
  - removes a queued `:command` message → `:ok`
  - removes a queued `:clear` marker → `:ok` (previously impossible)
  - removes a queued `:compact` marker → `:ok`
  - returns `{:error, :already_sent}` for a flushed/persisted message
  - returns `{:error, :not_found}` for an absent id
  - no broadcast on success
- `describe "Agent.prompt/3 :command opt removed"`:
  - passing `command: meta` to `Agent.prompt/3` no longer enqueues a
    command (regression guard — dispatch is via `Agent.command/3`)
- `describe "slash command dispatch (tiers)"`:
  - `/clear` → `Agent.clear`
  - `/compact foo` → `Agent.compact` with `%{prompt: "foo"}`
  - `/review-checklist src` → `Agent.command/3` with the right meta
  - `/grill-me extra` → `Agent.load_skill/3`
  - `/unknown` → verbatim pass-through
  - built-in shadows same-named custom command
  - custom command shadows same-named skill

In `planck_agent/test/planck/agent/message_test.exs`:

- `describe "to_ai_messages {:custom, :command}"`:
  - `invoked_by: :user` → `[%Planck.AI.Message{role: :user, ...}]`
  - `invoked_by: :assistant` → `[]` (stub)
- `describe "to_ai_messages {:custom, :skill}"`:
  - converts to `[%Planck.AI.Message{role: :user, content: [{:text, skill_content}]}]`

In `planck_headless/test/planck/headless_test.exs`:

- `describe "Headless.prompt/3 slash command dispatch"`:
  - resolves `/clear` and `/compact` against built-ins
  - resolves `/command-name` against `ResourceStore.commands` and calls
    `Agent.command/3` (not `Agent.prompt/3` with an opt) with the right
    `command_meta`
  - resolves `/skill-name` against `ResourceStore.skills` (full store) and
    calls `Agent.load_skill/3`
  - passes non-slash messages through unchanged
  - passes unknown `/<name>` through verbatim
- `describe "hot reload updates commands"`:
  - after `ResourceStore.reload/0` with a newly-added command, the
    dispatcher resolves it (`async: false` — touches global store)

In `planck_cli/test/.../session_controller_test.exs`:

- `describe "POST /api/sessions/:id/prompt with slash command"`:
  - `/clear` via HTTP clears the session
  - `/compact foo` via HTTP forces compaction with the prompt
- `describe "POST /api/sessions/:id/cancel_queued"`:
  - cancels a queued message while the agent is busy
  - returns 404 for an unknown message id
  - returns 404 for an already-flushed message
  - returns 404 for an unknown session

## Open question

~~**Session insertion API for tier 3 (skill injection).**~~ **Resolved** —
Tier 3 no longer uses tool-call simulation. `Agent.load_skill/3` enqueues a
`{:custom, :skill}` message directly; no Session insertion API is needed.

## Files touched

| File | Change |
|---|---|
| `planck_agent/lib/planck/agent.ex` | `Agent.clear/1`, `Agent.compact/2` (defers to `handle_continue`), `Agent.command/3`, `Agent.cancel_queued/2`, `Agent.load_skill/3`; remove `pending_commands` field + `PendingCommands` alias; `drain_control_markers/1` (strips markers only); `do_abort/1`, `start_queued_turn/1`; `handle_continue({:compact, args})`; remove `:command` opt branch from `handle_call({:prompt, ...})`; busy-path enqueue for `:clear` / `:compact` broadcasts `:message_queued` with `role` |
| `planck_agent/lib/planck/agent/pending_commands.ex` | **deleted** |
| `planck_agent/lib/planck/agent/session.ex` | `Session.clear/1` (`DELETE FROM messages`) |
| `planck_agent/lib/planck/agent/hooks/compactor.ex` | `compact/4` callback; `compact/4` dispatch passes `args:`; sidecar RPC path updated; `compact_opts` gains `args:` key |
| `planck_agent/lib/planck/agent/hooks/compactor/default.ex` | `@delegate_system_prompt` → EEx template; `compact/4` renders via `EExRenderer` |
| `planck_agent/lib/planck/agent/command.ex` | **new** — `Command.t()`, `load_all/1`, `from_file/1`, frontmatter parser |
| `planck_agent/lib/planck/agent/eex_renderer.ex` | **new** — shared `render/2` helper |
| `planck_agent/lib/planck/agent/message.ex` | `{:custom, :command}` and `{:custom, :skill}` clauses in `to_ai_messages/1` (`:clear` / `:compact` dropped by catch-all) |
| `planck_agent/lib/planck/agent/turn_context.ex` | `has_pending_input?/2` treats `{:custom, :skill}` as pending input |
| `planck_headless/lib/planck/headless.ex` | command dispatcher in `prompt/3` (parse + tier resolution); tier 2 calls `Agent.command/3`; tier 3 calls `Agent.load_skill/3`; `cancel_queued_message/2` passthrough |
| `planck_headless/lib/planck/headless/config.ex` | `commands_dirs` config (default `[".planck/commands", "~/.planck/commands"]`) |
| `planck_headless/lib/planck/headless/resource_store.ex` | `commands: [Command.t()]` field + `Command.load_all` in `load_resources/0` |
| `planck_headless/lib/planck/headless/watcher.ex` | watch `commands_dirs` |
| `planck_cli/lib/planck/web/api/session_controller.ex` | `cancel_queued/2` action + `ensure_session/1` helper |
| `planck_cli/lib/planck/web/api/schemas.ex` | `CancelQueued` schema |
| `planck_cli/lib/planck/web/router.ex` | `POST /api/sessions/:id/cancel_queued` route |
| `skills/planck_setup/references/api.md` | document the `cancel_queued` endpoint |
| `specs/compactors.md` | update `compact/4` signature + migration note |
