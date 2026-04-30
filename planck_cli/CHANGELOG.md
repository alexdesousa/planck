# Changelog

## Unreleased

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

## v0.1.0

First release of the Planck Web UI.

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
