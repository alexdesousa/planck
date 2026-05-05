# Changelog

## v0.1.0

### Server configuration via CLI flags and env vars

- `--port`/`PORT` — HTTP port (default: `4000`).
- `--ip`/`IP_ADDRESS` — bind address (default: `127.0.0.1`). Set to `0.0.0.0`
  for Docker or server hosting. Planck has no auth — localhost-only by default.
- `--host`/`HOST` — hostname for generated URLs (default: `localhost`).
- `--sname`/`NODE_SNAME` — Erlang short node name (default: `planck_cli`).
- `--cookie`/`NODE_COOKIE` — Erlang magic cookie (default: `planck`).
- `Planck.CLI.Config` resolves all server options via Skogsra; `put_*` functions
  allow overrides at runtime. `IpAddress` Skogsra type parses IP strings to tuples.
- Erlang distribution is started automatically at boot using the configured
  sname/cookie — no longer requires `elixir --sname` VM flag. In development,
  pass args after `--`: `mix run --no-halt -- --sname planck_cli`.

### Onboarding — setup modal

- `SetupModal` LiveComponent: 3-step modal (provider + credentials → model
  details → save location). Opens automatically when `default_model` is nil;
  blocks dismissal until at least one model is configured. Re-openable via ⚙
  in the status bar. Fetches available models from running local servers (2 s
  timeout, falls back to text input). Writes config via `configure_model/1`.
- Local model detail fields: display name, context window, supports-thinking,
  `default_opts` JSON textarea.

### Model selector

- `ModelSelectorModal` LiveComponent: lightweight single-step modal for
  switching an agent's model at runtime. Shows a dropdown of all available
  models pre-selected to the current model (matched by ID).
- Orchestrator card in agents sidebar is now clickable — opens the model
  selector for the orchestrator.
- Overlay top bar shows the current model as a NeoBrutalism pill button (⇄)
  that opens the model selector for the worker.
- `Agent.change_model/2` called on save; agents map updated with new display
  name and ID; agents sidebar card refreshed.

### NeoBrutalism dropdown component

- `Planck.Web.Components.dropdown/1` — reusable replacement for the OS-native
  `<select>`. Open/close via `JS.show`/`hide`; full-screen backdrop for
  outside-click dismiss; option push includes `value:` and `extra:` directly
  on `JS.push` for reliable routing.
- Replaces the radio button list in the New Session team selector.

### Chat empty state

- `ChatComponent` renders a welcome card (Markdown) from `team_description`
  stored in session metadata when there are no messages. Dynamic teams show a
  translated welcome with Planck feature highlights. Teams with no description
  show a muted "Send a message to start." fallback (translated).

### HTTP API

- REST + SSE API at `/api` served by the same Phoenix app as the Web UI
- `GET /api/sessions` — list sessions; `POST` — start; `DELETE` — close
- `POST /api/sessions/:id/prompt` — send prompt, auto-resumes closed sessions
- `POST /api/sessions/:id/abort` — abort all agents
- `GET /api/sessions/:id/events` — SSE stream; `?agent_id=` filters to a
  single agent (subscribes to `"agent:#{id}"` PubSub topic, injects
  `agent_id` into payloads to match the session-scoped frame shape)
- `GET /api/teams`, `GET /api/teams/:alias`, `GET /api/models` — read-only
  resource endpoints
- `open_api_spex` (~> 3.21): OpenAPI spec at `/api/openapi`, Swagger UI at
  `/api/swaggerui`; all controllers annotated with `open_api_operation/1`,
  full schema definitions with examples in `Planck.Web.API.Schemas`
- Payload sanitisation in SSE: non-JSON-serializable values (tuples, pids)
  converted to their `inspect` string before encoding
- `:stop` message in `event_loop` allows tests to terminate the SSE stream
  gracefully via `Task.yield`

### Internationalisation (i18n)

- Gettext backend (`Planck.Web.Gettext`) with English and Spanish translations
- All user-visible strings use `pgettext("context", "msgid")` for translator context
- Locale detection via `Planck.Web.Locale.Plug` with priority chain:
  `locale` in config.json → session → `?locale=` param / `Accept-Language` → `"en"`
- `locale` config key supported in `.planck/config.json` and `~/.planck/config.json`
- Locale restored per-LiveView-process in `SessionLive.mount/3` (LiveView runs in a
  separate process from the HTTP request that set the locale)
- `gettext` check added to `./check planck_cli`: runs `mix gettext.extract --merge`
  and fails if any string in source is missing a translation in a `.po` file

### Architecture — LiveComponent decomposition

- `SessionLive` is a thin event router; all stateful UI lives in LiveComponents
- `SessionsSidebar` — owns sessions list, delete confirmation modal, new session
  modal; forwards Headless calls to `SessionLive` via `send(self(), ...)`
- `ChatComponent` — owns streaming entries, agent author info, entry toggling
- `AgentsSidebar` — owns per-agent usage/cost/context/status in real-time via
  `usage_delta` events; handles `:worker_spawned` for dynamic agent appearance
- `PromptInput` — owns textarea text, stop/stop-all controls
- `StatusBar` — owns total usage/cost and sidecar status; updates via deltas
- `EditMessageModal` — owns edit textarea, calls `Headless.rewind_to_message/3`

### Chat

- `ChatEntries` module classifies session rows into typed entry structs:
  `:user`, `:text`, `:thinking`, `:tool`, `:inter_agent_in`, `:error`,
  `:summary`, `:agent_response`
- Streaming text rendered as plain escaped text; Earmark parses only when
  streaming ends (avoids markdown flicker on incomplete syntax)
- Thinking blocks fixed: stable id `"think-#{agent_id}"` so all deltas update
  a single block instead of creating new ones
- Smart scroll: auto-scroll only when near the bottom; `initialLoad` flag forces
  scroll on initial content load
- Tool call blocks collapsible; expanding no longer hijacks scroll position
- Edit button always visible on user messages (NeoBrutalism — no hover-hide)
- Agent context overlay only opens for workers; orchestrator events already
  in chat-main (fixes text appearing doubled when overlay was open)
- PubSub subscription cleaned up on session switch (fixes doubled text after
  switching back to a previous session)

### Agent cards

- Real-time updates via `usage_delta` events — no polling
- Shows: `↓input ↑output` tokens, `$cost`, `ctx X%` (estimated context usage)
- `ctx X%` uses `Message.estimate_tokens/1` (chars/4) against model context window
- Streaming indicator changed to solid white dot (always visible on colored cards)
- `list_skills` added to tool list display in verbose `list_team`

### Sessions sidebar

- Delete confirmation modal before removing a session
- NeoBrutalism `×` delete button (red, always visible)
- New session team selector uses radio button list (not OS `<select>`)
- Session items styled with `border-2 border-black` and hover shadow

### Status bar + dark mode

- Manual dark mode toggle (☾/☀) with `localStorage` persistence;
  system preference used as fallback
- `data-theme` attribute on `<html>`; Tailwind v4 custom variant `dark:`
- Sidecar status hidden on desktop (already in agents sidebar footer)

### Prompt input

- Input active while streaming: textarea and Send remain enabled during
  `:streaming` so users can queue a follow-up without waiting for the current
  turn to finish. The agent enqueues it and processes it after the turn ends.
  Only fully disabled during `:waiting` (before streaming starts) to prevent
  double-submits. Stop / Stop All remain visible alongside Send while streaming.

### Infrastructure

- `.mcp.json` added (gitignored) for Tidewave MCP server in dev
- `planck_cli/README.md` documents `--sname` requirement for sidecar support
- `check` script at monorepo root: runs format + compile + credo + test +
  dialyzer across all `planck_*` packages; supports `./check [package...]`
