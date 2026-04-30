# Planck Web UI

The Web UI is a Phoenix LiveView application bundled inside `planck_cli`.
It lives at `planck_cli/lib/planck/web/` and is a rendering surface only —
all business state comes from `planck_headless` and `planck_agent` via
`Phoenix.PubSub`.

Accessed at `http://localhost:4000` when running:

```bash
PLANCK_LOCAL=true elixir --sname planck_cli -S mix run --no-halt
```

The `--sname` flag is required for the optional sidecar to connect back.

## Layout

```
┌──────────┬──────────────────────────────────┬───────────────┐
│ Sessions │                                  │  orchestrator │
│          │        Chat / Context            │  ctx 12%      │
│ sess1  × │        (scrollable)              │  ↓1.2k ↑0.3k │
│ sess2  × │                                  ├───────────────┤
│ ...      │                                  │  builder      │
│          │                                  │  streaming ●  │
│ [+ New]  │                                  │  ↓0.8k ↑0.1k │
│          ├──────────────────────────────────┴───────────────┤
│          │  prompt input (Shift+Enter = newline, Enter = submit) │
│          ├───────────────────────────────────────────────────┤
│          │ ☾ session-name v0.1.0    ↓12k ↑3k  $0.02        │
└──────────┴───────────────────────────────────────────────────┘
```

Sidebars collapse to drawer overlays on mobile (`md` breakpoint).

## LiveComponent architecture

`session_live.ex` is a thin event router. All stateful UI is owned by
independent LiveComponents:

| Component | Module | State it owns |
|---|---|---|
| Sessions sidebar | `SessionsSidebar` | delete confirmation, new session modal |
| Chat view | `ChatComponent` | streaming entries, agent author info |
| Agents sidebar | `AgentsSidebar` | per-agent usage/cost/status, sidecar |
| Prompt input | `PromptInput` | textarea text, streaming/waiting flags |
| Status bar | `StatusBar` | total usage/cost, sidecar status |
| Edit message modal | `EditMessageModal` | edited text |

`SessionLive` subscribes to `"session:#{id}"` and `"planck:sidecar"` via
PubSub and routes events to the right component via `send_update/3`.

## Sessions sidebar — `SessionsSidebar`

- Lists all sessions from disk; active ones show a green dot
- Clicking switches to that session (resumes if inactive)
- Red `×` delete button on each item with a confirmation modal before deleting
- **[+ New]** opens the new session modal (team selector + optional name field)
- All interaction is owned by the LiveComponent; results are forwarded to
  `SessionLive` via `send(self(), ...)` messages for Headless calls

## Chat — `ChatComponent`

- Shows the full message history for the active session or agent perspective
- Streaming text rendered as plain escaped text to avoid markdown flicker;
  Earmark parses only when the entry's `:streaming` flag is false
- Tool call blocks are collapsible (`▶`/`▼`); `toggle_entry` event handled locally
- Thinking blocks collapse to a single block during streaming (stable id fix)
- Scroll-to-bottom on new content; smart scroll preserves position when user
  has scrolled up to read history or expand a tool call
- **Edit button** on user messages (always visible per NeoBrutalism): clicking
  opens `EditMessageModal` which calls `Headless.rewind_to_message/3` on confirm
- Entries are classified by `ChatEntries` module into typed structs:
  `:user`, `:text`, `:thinking`, `:tool`, `:inter_agent_in`, `:error`, `:summary`, `:agent_response`

## Agents sidebar — `AgentsSidebar`

- One card per agent (orchestrator neutral card, workers colored by spawn order)
- Each card: name, type, model, `↓input ↑output` tokens, cost, `ctx X%`
- `ctx X%` — estimated current context window usage (`Message.estimate_tokens`
  chars/4 approximation against `model.context_window`)
- Streaming indicator: solid white pulsing dot (visible against card color)
- Live updates via `usage_delta` events — no polling required
- Sidecar status in the footer (hidden on desktop, visible on mobile where the
  sidebar is behind a drawer)
- Clicking an agent card opens the agent context overlay (workers only; the
  orchestrator's view is already chat-main)
- Handles `:worker_spawned` events to add new dynamic agents without page reload

## Status bar — `StatusBar`

- Session name and version on the left; dark mode toggle (☾/☀) next to version
- Total `↓input ↑output` tokens and cost (`$X.XX`) on the right
- Sidecar status visible on mobile only (already shown in agents sidebar on desktop)
- Accumulates usage via `usage_delta` deltas in real-time

## Prompt input — `PromptInput`

- Multi-line textarea; Shift+Enter inserts newline, Enter submits
- **Input active while streaming**: textarea and Send remain enabled during
  `:streaming` so the user can queue a follow-up message while the agent is
  still responding. The agent enqueues it and processes it after the current
  turn ends. Only disabled during `:waiting` (the brief moment before streaming
  starts) to prevent double-submits.
- **Stop** and **Stop All** buttons visible whenever `:streaming` or `:waiting`
- Firefox fallback: `CSS.supports("field-sizing", "content")` detected; if false,
  sets 5-line height (desktop) / 3-line (mobile) with manual resize-on-input
- `streaming` and `waiting` flags passed as template assigns from `SessionLive`

## Internationalisation (i18n)

The Web UI uses Elixir Gettext (`use Gettext.Backend, otp_app: :planck_cli`) with
a single `default` domain. All user-visible strings use `pgettext("context", "msgid")`
so translators have context alongside every string.

### Locale priority (highest first)

1. `locale` key in `.planck/config.json` or `~/.planck/config.json`
2. Locale stored in the Phoenix session (carries the resolved locale across
   LiveView reconnects)
3. `?locale=<tag>` query param or browser `Accept-Language` header
4. Fallback: `"en"`

Locale detection runs in `Planck.Web.Locale.Plug` (browser pipeline) and is
restored in `SessionLive.mount/3` via the session key + `get_connect_params/1`
for the LiveView process.

### Translation files

```
planck_cli/priv/gettext/
  default.pot               — extracted template (generated by mix gettext.extract)
  en/LC_MESSAGES/default.po — English
  es/LC_MESSAGES/default.po — Spanish
```

### Adding a new locale

1. Create `priv/gettext/<locale>/LC_MESSAGES/default.po` (copy the `.pot` file,
   set `Language:`, fill in `msgstr` values).
2. Add the locale tag to the `locales:` list in `router.ex`:
   ```elixir
   plug Planck.Web.Locale.Plug, gettext: Planck.Web.Gettext, locales: ["en", "es", "fr"]
   ```
3. Run `./check planck_cli` — the `gettext` step will fail if any string is
   missing a translation, showing exactly which entries need filling in.

## Dark mode

Manual toggle (☾/☀) in the status bar. `localStorage` persists the choice
across sessions; system preference is used as fallback when no override is set.
Implemented via `window.toggleTheme()` and a `data-theme` attribute on `<html>`.

## New session modal (inside `SessionsSidebar`)

Team selector is a styled radio button list (not a `<select>`) so it follows
the NeoBrutalism design system. Optional name field. Events are handled by the
LiveComponent and forwarded to `SessionLive` via `send(self(), :create_session)`.

## Edit message modal — `EditMessageModal`

Opens when the user clicks the edit button on a user message. Shows the message
text in a 5-line min-height textarea. On confirm, calls
`Headless.rewind_to_message/3` (synchronous — waits for truncation + re-prompt)
then reloads `ChatComponent` from session. The modal is a LiveComponent with its
own `phx-target`.

## Data flow

```
planck_agent PubSub
  "session:#{id}"  → :turn_start, :turn_end, :text_delta, :tool_start/end,
                     :usage_delta, :worker_spawned, :compacting, :compacted
  "planck:sidecar" → :building, :starting, :connected, :disconnected, :exited
        ↓
Planck.Web.SessionLive (thin router)
  Dispatches events to components via send_update/3
        ↓
AgentsSidebar  ← :turn_start/end (status), :usage_delta (usage/cost/context)
ChatComponent  ← :text_delta, :tool_start/end, :turn_end (reload), ...
StatusBar      ← :usage_delta (totals), sidecar events
PromptInput    ← streaming/waiting from SessionLive template assigns
```

`SessionLive` never reads state from `planck_headless` reactively — all state
arrives via PubSub. Writes go through `Planck.Headless.prompt/2`,
`Planck.Agent.abort/1`, `Planck.Headless.rewind_to_message/3`, etc.

## Module structure

```
planck_cli/lib/planck/web/
  web.ex                     — Phoenix app entry point (use :live_view, :html)
  router.ex                  — GET / → SessionLive
  endpoint.ex
  components.ex              — Function components: agent_card, orchestrator_card,
                               tool_block, thinking_block, sidecar_status,
                               format_number/cost/context helpers
  live/
    session_live.ex          — Event router; owns session switching, overlay state
    session_live.html.heex
    sessions_sidebar.ex      — LiveComponent: sessions list, new/delete modals
    sessions_sidebar.html.heex
    chat_component.ex        — LiveComponent: streaming chat entries
    chat_component.html.heex
    chat_entries.ex          — Pure entry classification (no LiveView deps)
    agents_sidebar.ex        — LiveComponent: agent cards, real-time updates
    agents_sidebar.html.heex
    agents_sidebar.html.heex
    prompt_input.ex          — LiveComponent: textarea + abort controls
    prompt_input.html.heex
    status_bar.ex            — LiveComponent: usage totals + dark mode toggle
    status_bar.html.heex
    edit_message_modal.ex    — LiveComponent: edit + rewind flow
    edit_message_modal.html.heex
```

## Design system

### Style: NeoBrutalism via Tailwind CSS v4

All components follow the NeoBrutalism aesthetic from RetroUI:

- **Borders:** `border-2 border-black` everywhere
- **Shadows:** `shadow-[2px_2px_0px_#000]` at rest;
  `hover:shadow-[4px_4px_0px_#000] hover:-translate-x-0.5 hover:-translate-y-0.5`
  on interactive elements; `transition-all` for snap
- **Corners:** sharp — no rounding
- **Typography:** `font-mono` for all data (tokens, model names, code);
  `font-bold` for headings and labels

### Color tokens — `data-theme` attribute

Dark/light mode via `[data-theme="dark"]` on `<html>` (Tailwind v4 custom variant).
CSS variables defined in `assets/css/app.css`:

```css
:root { --background, --foreground, --card, --primary, --muted, --accent, --border, ... }
[data-theme="dark"] { /* overrides */ }
@custom-variant dark (&:where([data-theme=dark], [data-theme=dark] *));
```

### Agent colors

Orchestrator: neutral `bg-card` with `var(--primary)` outline.
Workers cycle through an 8-color palette by spawn order:

```elixir
@agent_colors [
  %{bg: "#EA435F", text: "#ffffff"},  # red
  %{bg: "#AAFC3D", text: "#000000"},  # lime
  %{bg: "#ffdb33", text: "#000000"},  # yellow
  %{bg: "#C4A1FF", text: "#000000"},  # lavender
  %{bg: "#F07200", text: "#ffffff"},  # orange
  %{bg: "#599D77", text: "#ffffff"},  # green
  %{bg: "#5F4FE6", text: "#ffffff"},  # purple
  %{bg: "#FE91E9", text: "#000000"},  # pink
]
```

### Streaming indicator

Worker cards show a solid white pulsing dot (`bg-white animate-pulse`) when
`:streaming`. White is always visible against the saturated card backgrounds.

## HTTP API

A REST + SSE API served by the same Phoenix app at `/api`. All endpoints
return JSON. An OpenAPI spec is served at `/api/openapi`; Swagger UI at
`/api/swaggerui`.

### Endpoints

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/sessions` | List all sessions |
| `POST` | `/api/sessions` | Start a session (`template?`, `name?`) |
| `GET` | `/api/sessions/:id` | Session info + agent list |
| `DELETE` | `/api/sessions/:id` | Close session (file retained) |
| `POST` | `/api/sessions/:id/prompt` | Send prompt; auto-resumes if closed |
| `POST` | `/api/sessions/:id/abort` | Abort all agents |
| `GET` | `/api/sessions/:id/events` | SSE event stream |
| `GET` | `/api/teams` | List registered teams |
| `GET` | `/api/teams/:alias` | Team detail + members |
| `GET` | `/api/models` | Available models |

### SSE event stream

`GET /api/sessions/:id/events` subscribes to all agents in the session.
Add `?agent_id=<id>` to filter to a single agent — the frame shape is
identical in both modes (`agent_id` is injected for the single-agent case
since `"agent:#{id}"` PubSub payloads do not carry it).

The connection stays open until the client disconnects. A `: keepalive`
comment is sent every 25 seconds to prevent proxy timeouts. The controller
handles a `:stop` message in tests to terminate the loop gracefully.

### OpenAPI / Swagger

`Planck.Web.API.Spec` builds the OpenAPI 3.0 spec via `open_api_spex`.
Controllers declare `open_api_operation/1` callbacks; schemas live in
`Planck.Web.API.Schemas`. The spec is cached by
`OpenApiSpex.Plug.PutApiSpec` in the endpoint.

### Module structure

```
planck_cli/lib/planck/web/api/
  spec.ex               — OpenApiSpex spec builder
  schemas.ex            — All request/response schema modules
  session_controller.ex — Sessions resource + prompt/abort actions
  event_controller.ex   — SSE stream (session scope + ?agent_id filter)
  team_controller.ex    — Teams resource (read-only)
  model_controller.ex   — Models list (read-only)
```

## Dependencies

```elixir
{:phoenix, "~> 1.8"},
{:phoenix_live_view, "~> 1.1"},
{:phoenix_html, "~> 4.0"},
{:bandit, "~> 1.0"},
{:earmark, "~> 1.4"},    # Markdown rendering for completed chat entries
{:gettext, "~> 0.26"},   # i18n — pgettext/2 with msgctxt in .po files
{:highlight_js, ...},    # Code block syntax highlighting via JS
{:open_api_spex, "~> 3.21"},         # OpenAPI spec generation + Swagger UI
{:tidewave, "~> 0.1", only: :dev}  # MCP server for live debugging
```

No Ecto — the Web UI is a rendering surface only. All persistence goes through
`planck_headless` and `planck_agent`.
