# Planck Web UI

The Web UI is a Phoenix LiveView application bundled inside `planck_cli`.
It lives in `planck_cli/lib/planck/web/` and is a rendering surface only —
all state comes from `planck_headless` via `Phoenix.PubSub`.

Accessed at `http://localhost:4000` when running `planck --web`.

Supports **light and dark mode** via Tailwind's `dark:` variant and the
CSS variable tokens defined above. Dark mode follows the system preference
(`prefers-color-scheme`) automatically — no manual toggle needed.

## Layout

```
┌──────────┬──────────────────────────────────┬───────────────┐
│ Sessions │                                  │  orchestrator │
│          │        Context / Chat            │  model: ...   │
│ session1 │        (scrollable)              │  usage: ...   │
│ session2 │                                  ├───────────────┤
│ ...      │                                  │  planner      │
│          │                                  │  model: ...   │
│ [+ New]  │                                  │  usage: ...   │
│          │                                  ├───────────────┤
│          │                                  │  builder      │
│          │                                  │  ...          │
├──────────┼──────────────────────────────────┴───────────────┤
│          │ > prompt input (Shift+Enter newline, Enter submit)│
│          ├───────────────────────────────────────────────────┤
│          │ session-name  v0.1.0    total: 12k  .planck/sidecar│
└──────────┴───────────────────────────────────────────────────┘
```

### Left sidebar — sessions

- Lists all sessions (active shown first, then stored on disk)
- Active sessions have a green indicator; stored sessions are dimmed
- Clicking a session switches the main view to that session's context
- **[+ New]** button opens a new session dialog:
  - Team selector (dropdown of available team aliases, or "Dynamic" for default)
  - Optional session name field
  - Confirm / Cancel

### Context / chat panel (centre, main)

- Displays the full message history of the active view
- Scrollable with mouse wheel
- Each message labelled by agent name and role
- Tool calls rendered as **collapsible blocks** — collapsed by default, click
  to expand:

  ```
  ▶ bash  [expand]
  ```

  Expanded:

  ```
  ▼ bash  [collapse]
    $ mix test
    ...30 tests, 0 failures
  ```

- Streaming responses show a blinking cursor at the end of the active agent's
  text

### Right sidebar — agents

- One card per agent (orchestrator first, workers below in spawn order)
- Each card shows: agent name, type, model, current usage, active/idle status
- Cards have distinct colors per agent type
- Sidecar status below the agent list (same as TUI)
- **Clicking an agent card opens the agent context overlay**

### Prompt input

- Multi-line textarea; Shift+Enter inserts a newline, Enter submits
- Abort button (×) next to the input cancels the current turn
- **↑ when the cursor is on the first line of an empty input** — loads the
  most recent user message. Pressing ↑ again goes further back through user
  messages (skipping agent responses and tool calls). ↓ moves forward again.
- **Submitting an edited historical message** — truncates the session at that
  point (all messages after the selected one are removed via `rewind/2`) then
  submits the edited text. The conversation rewinds to that moment.

### Status bar (bottom)

Same content as TUI: session name + version (left), total tokens + sidecar
path (right).

## Agent context overlay

Triggered by clicking an agent card. Opens a full-screen overlay over the
entire layout showing that agent's complete message history. Scrollable with
mouse wheel. **Close button (×)** in the top-right corner returns to the
session view.

Tool blocks inside the overlay are also collapsible.

## Empty state / first launch

When planck starts with no existing sessions, it **automatically creates a
new session** with the default dynamic team (single orchestrator). The user
lands directly in the chat panel with the prompt ready — no welcome screen,
no wizard.

The orchestrator's system prompt already includes the Planck guides
(configuration, teams, skills, sidecars), so the user can immediately ask
it to set up their project:

> "Create a team with a planner, builder, and reviewer for this project"
> "Build a sidecar that sends Telegram notifications when a phase completes"
> "Set up Planck to use my local Ollama server"

The agent fetches the relevant guide and implements the configuration. Planck
configures itself through itself.

## New session dialog

```
┌─────────────────────────────┐
│  New Session                │
│                             │
│  Team:  [Dynamic        ▼]  │
│  Name:  [               ]   │
│                             │
│  [Cancel]        [Create]   │
└─────────────────────────────┘
```

The team dropdown lists all loaded team aliases from `ResourceStore`.
Selecting "Dynamic" uses the default single-orchestrator setup.

## Data flow

```
planck_headless PubSub
  "session:#{id}"  → chat messages, tool events, usage deltas
  "agent:#{id}"    → per-agent events for sidebar card updates
  "planck:sidecar" → sidecar lifecycle for status indicator
        ↓
Planck.Web.SessionLive (LiveView)
  handle_info/2 receives PubSub events
  assigns: messages, agents, usage, sidecar_status, active_overlay
        ↓
Heex templates re-render on assign changes
```

The LiveView never calls `planck_headless` for reads — all state arrives via
PubSub. Writes go through `Planck.Headless.prompt/2` and
`Planck.Agent.abort/1`.

## Module structure

```
planck_cli/lib/planck/web/
  web.ex                — Phoenix application entry point
  router.ex             — Routes: GET / → SessionLive
  live/
    session_live.ex     — Main LiveView: session context + agent sidebar
    session_live.html.heex
  components/
    chat.ex             — Chat message list component
    tool_block.ex       — Collapsible tool call/result component
    agent_card.ex       — Agent sidebar card component
    agent_overlay.ex    — Full-screen agent context overlay component
    session_list.ex     — Left sidebar session list component
    new_session_modal.ex — New session dialog component
    status_bar.ex       — Bottom status bar component
  endpoint.ex
  telemetry.ex
```

## Design system

### Style: NeoBrutalism via Tailwind CSS

All components share a NeoBrutalism aesthetic — a nod to both brutalist design
and Elixir's purple identity. Key traits:

- **Borders:** `border-2 border-black` everywhere. No shadows from Tailwind's
  default scale — use arbitrary offset shadows instead.
- **Shadows:** `shadow-[4px_4px_0px_#000]` at rest;
  `hover:shadow-[6px_6px_0px_#000] hover:-translate-x-0.5 hover:-translate-y-0.5`
  on interactive elements. `transition-all duration-100` for snap.
- **Corners:** sharp — `rounded-none` or `rounded-sm` (2px) maximum.
- **Typography:** monospace (`font-mono`) for code, tool output, model names,
  and token counts. Bold sans-serif (`font-bold`) for headings and agent names.
- **Backgrounds:** off-white (`bg-stone-50`) for the page; white (`bg-white`)
  for panels; agent card colors from the purple palette.
- **No gradients.** No blur. No opacity tricks. Flat and direct.

### Color tokens — RetroUI palette

We use the same CSS variables as RetroUI's design system, defined in
`assets/css/app.css`. This gives us the exact NeoBrutalism purple aesthetic
without installing any React library.

```css
:root {
  --radius: 0;
  --background: #f5f5f5;
  --foreground: #1a1a1a;
  --card: #FFFFFF;
  --card-foreground: #f5f5f5;
  --primary: #5F4FE6;
  --primary-hover: #4938C2;
  --primary-foreground: #fff;
  --secondary: #3a3a3a;
  --secondary-foreground: #f5f5f5;
  --muted: #CFCCEA;
  --muted-foreground: #5B5686;
  --accent: #FED13B;
  --accent-foreground: #000000;
  --destructive: #EF4444;
  --destructive-foreground: #fff;
  --border: #3a3a3a;
}

.dark {
  --background: #0f0f12;
  --foreground: #f5f5f5;
  --card: #1a1a1d;
  --card-foreground: #eaeaea;
  --primary: #7b6df5;
  --primary-hover: #5F4FE6;
  --primary-foreground: #fff;
  --secondary: #2a2a2e;
  --secondary-foreground: #eaeaea;
  --muted: #3d395a;
  --muted-foreground: #a49fce;
  --accent: #FED13B;
  --accent-foreground: #000;
  --destructive: #EF4444;
  --destructive-foreground: #fff;
  --border: #2e2e32;
}
```

Wired into Tailwind via `tailwind.config.js`:

```js
theme: {
  extend: {
    colors: {
      background: "var(--background)",
      foreground: "var(--foreground)",
      card: "var(--card)",
      primary: {
        DEFAULT: "var(--primary)",
        hover: "var(--primary-hover)",
        foreground: "var(--primary-foreground)"
      },
      secondary: {
        DEFAULT: "var(--secondary)",
        foreground: "var(--secondary-foreground)"
      },
      muted: {
        DEFAULT: "var(--muted)",
        foreground: "var(--muted-foreground)"
      },
      accent: {
        DEFAULT: "var(--accent)",
        foreground: "var(--accent-foreground)"
      },
      destructive: "var(--destructive)",
      border: "var(--border)"
    },
    borderRadius: { DEFAULT: "var(--radius)" }
  }
}
```

### Agent colors

Agent cards cycle through a fixed palette derived from all RetroUI themes.
Colors are assigned by spawn order — orchestrator always gets index 0, each
new worker gets the next color in the list. The palette is chosen for maximum
visual contrast and dark-mode legibility.

```elixir
# In Planck.Web.Components — shared between Web UI and referenced by TUI
@agent_colors [
  # light bg          dark bg       text (both modes)
  {"#EA435F",        "#EA435F",     "#ffffff"},  # red
  {"#AAFC3D",        "#AAFC3D",     "#000000"},  # lime
  {"#ffdb33",        "#ffdb33",     "#000000"},  # yellow
  {"#C4A1FF",        "#C4A1FF",     "#000000"},  # lavender
  {"#F07200",        "#F07200",     "#000000"},  # orange
  {"#599D77",        "#599D77",     "#ffffff"},  # green
  {"#5F4FE6",        "#7b6df5",     "#ffffff"},  # purple
  {"#FE91E9",        "#FE91E9",     "#000000"},  # pink
]

# Orchestrator always gets a neutral card — white with a purple border.
# Saturated colors are reserved for workers who are doing the active work.
@orchestrator_color {"#FFFFFF", "#1a1a1d", "#000000"}  # {light, dark, text}
```

The orchestrator card uses white background + `var(--primary)` border (2px,
offset shadow) to distinguish it as the coordinator without competing
visually with active worker cards.

Worker colors cycle through `@agent_colors` by spawn order — first worker
gets index 0 (red), second gets index 1 (lime), etc. If a session has more
than 8 workers, the list wraps.

Both TUI and Web UI use the same index-to-color mapping so agent colors
feel consistent across interfaces.

The accent yellow (`#FED13B`) is used for the active streaming indicator
pulse and hover highlights on interactive elements.

### Component library — `Planck.Web.Components`

All UI elements are Phoenix function components in
`planck_cli/lib/planck/web/components/`. Each component is self-contained:
markup + Tailwind classes, no external CSS files.

```elixir
# Example — agent card
attr :agent, :map, required: true
attr :active, :boolean, default: false

def agent_card(assigns) do
  ~H"""
  <div
    class={[
      "border-2 border-black p-3 cursor-pointer transition-all duration-100",
      "shadow-[4px_4px_0px_#000] hover:shadow-[6px_6px_0px_#000]",
      "hover:-translate-x-0.5 hover:-translate-y-0.5",
      agent_bg(@agent.type)
    ]}
    phx-click="open_agent" phx-value-id={@agent.id}
  >
    <div class="flex justify-between items-center">
      <span class="font-bold font-mono"><%= @agent.name %></span>
      <span class={["w-2 h-2 rounded-full border border-black",
                    if(@active, do: "bg-purple-500", else: "bg-stone-300")]} />
    </div>
    <p class="text-xs font-mono mt-1"><%= @agent.model %></p>
    <p class="text-xs font-mono"><%= @agent.usage %> tokens</p>
  </div>
  """
end
```

Components to implement:

| Component | Description |
|---|---|
| `agent_card/1` | Agent sidebar card with color, status dot, click handler |
| `chat_message/1` | Single message with agent label and role badge |
| `tool_block/1` | Collapsible tool call — header always visible, output toggled |
| `prompt_input/1` | Textarea with submit on Enter, newline on Shift+Enter, abort button |
| `status_bar/1` | Bottom bar with session info and sidecar status |
| `session_item/1` | Session list entry with active indicator |
| `new_session_modal/1` | Team selector + name input dialog |
| `agent_overlay/1` | Full-screen overlay with close button and scrollable chat |
| `sidecar_status/1` | Pill indicator: `● connected`, `○ building…`, etc. |

### Typography scale

| Element | Classes |
|---|---|
| Page heading | `text-xl font-bold font-mono` |
| Agent name | `text-sm font-bold font-mono` |
| Model / metadata | `text-xs font-mono text-stone-600` |
| Chat message body | `text-sm leading-relaxed` |
| Tool output | `text-xs font-mono whitespace-pre-wrap` |
| Status bar | `text-xs font-mono` |

## Dependencies (added to planck_cli)

```elixir
{:phoenix, "~> 1.7"},
{:phoenix_live_view, "~> 1.0"},
{:phoenix_html, "~> 4.0"},
{:bandit, "~> 1.0"}
```

Tailwind CSS is configured via `mix phx.new --tailwind` (already part of the
standard Phoenix generator). No external component libraries — everything is
implemented as function components using utility classes.

No Ecto — the Web UI is a rendering surface only. All persistence goes through
`planck_headless`.
