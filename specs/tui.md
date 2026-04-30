# Planck TUI

The TUI is the primary interface for `planck_cli`. It lives in
`planck_cli/lib/planck/tui/` and is built with
[ex_ratatui](https://hex.pm/packages/ex_ratatui). It is a rendering surface
only — all state comes from `planck_headless` via `Phoenix.PubSub`.

## Layout

```
┌─────────────────────────────────────────┬───────────────────┐
│                                         │  ┌─────────────┐  │
│                                         │  │ orchestrator│  │
│           Context / Chat                │  │ model: ...  │  │
│           (scrollable)                  │  │ usage: ...  │  │
│                                         │  └─────────────┘  │
│                                         │  ┌─────────────┐  │
│                                         │  │  planner    │  │
│                                         │  │ model: ...  │  │
│                                         │  │ usage: ...  │  │
│                                         │  └─────────────┘  │
│                                         │         ...       │
├─────────────────────────────────────────┴───────────────────┤
│ > prompt input (Shift+Enter for newline, Enter to submit)   │
├─────────────────────────────────────────────────────────────┤
│ session-name  v0.1.0       total: 12k tokens  .planck/sidecar│
└─────────────────────────────────────────────────────────────┘
```

### Context / chat panel (left, main)

- Displays the full message history of the active view (session or agent)
- Scrollable with mouse wheel and keyboard (↑↓, Page Up/Down)
- Each message is labelled by agent name and role
- Tool calls are rendered as a **bordered box** with the tool name as the
  header and the full output inside — no collapsing

  ```
  ┌─ bash ──────────────────────────────┐
  │ $ mix test                          │
  │ ...30 tests, 0 failures             │
  └─────────────────────────────────────┘
  ```

- Streaming responses show a blinking cursor at the end of the active agent's
  text

### Agent sidebar (right)

- One card per agent (orchestrator first, workers below in spawn order)
- Each card shows: agent name, type, model, current usage (input/output tokens),
  and active/idle status
- **Orchestrator card** uses a neutral style — white/default background with
  a purple border, to distinguish the coordinator without dominating the sidebar
- **Worker cards** cycle through the shared `@agent_colors` palette by spawn
  order (see `specs/web.md`). The same index produces the same color in both
  TUI and Web UI
- Sidecar connection status shown below the agent list:
  `● connected  .planck/sidecar` or `○ building…` / `○ disconnected`
- Sidebar is scrollable if there are more cards than screen height allows

### Prompt input

- Single-line by default; Shift+Enter inserts a newline
- Enter submits
- Ctrl+C aborts the current agent turn (sends abort signal, agent returns to
  idle)
- **↑ on empty prompt** — loads the most recent user message into the input;
  pressing ↑ again goes further back through user messages (skipping agent
  responses and tool calls). ↓ moves forward again. Navigating away from the
  populated text clears the history cursor.
- **Submitting an edited historical message** — truncates the session at that
  point (all messages after the selected one are removed via `rewind/2`) then
  submits the edited text. The conversation effectively rewinds to that moment.

### Status bar (bottom)

Left: `<session-name>  planck v<version>`
Right: `<total tokens>  <sidecar path or "no sidecar">`

## Theme

The TUI uses a single fixed light theme — no dark mode. The color palette
mirrors the Web UI's light tokens: off-white background, black borders, purple
accents, and the shared agent color list for worker cards.

## Empty state / first launch

Same behaviour as the Web UI: when planck starts with no existing sessions,
a new session is automatically created with the default dynamic team. The
user lands directly at the prompt — no welcome screen or wizard.

## Commands

Typed at the prompt with a `/` prefix:

| Command | Description |
|---|---|
| `/new [team]` | Start a new session; optionally specify a team alias |
| `/resume <name>` | Resume a previous session by name or id |
| `/team` | Show the current team configuration |
| `/agent <name>` | Open the agent context overlay for the named agent |
| `/abort` | Abort the current turn (same as Ctrl+C) |
| `/help` | Show the command list inline |

## Agent context overlay

Triggered by `/agent <name>`. Opens a full-screen overlay showing that agent's
complete message history (same format as the main context panel). Scrollable
with mouse wheel. **Esc** closes the overlay and returns to the session view.

## Data flow

```
planck_headless PubSub
  "session:#{id}"  → chat messages, tool events, usage deltas
  "agent:#{id}"    → per-agent events for sidebar card updates
  "planck:sidecar" → sidecar lifecycle events for status indicator
        ↓
Planck.TUI.EventHandler (GenServer)
  maintains local state: messages, agent cards, usage totals
        ↓
ex_ratatui render loop
  re-renders on every state change
```

The TUI never calls `planck_headless` directly for reads — all state arrives
via PubSub. Writes (prompt submit, abort) go through `Planck.Headless.prompt/2`
and `Planck.Agent.abort/1`.

## Module structure

```
planck_cli/lib/planck/tui/
  tui.ex              — Application entry point; starts headless + TUI supervisor
  event_handler.ex    — GenServer; subscribes to PubSub, maintains render state
  renderer.ex         — Pure function: state → ratatui widget tree
  widgets/
    chat.ex           — Chat panel widget
    agent_card.ex     — Single agent card widget
    tool_block.ex     — Bordered tool call/result widget
    prompt.ex         — Input widget
    status_bar.ex     — Bottom status bar widget
    overlay.ex        — Full-screen overlay wrapper
```
