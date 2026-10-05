# Hot Reload — Skills, Tools, and Config

## Overview

Two related changes:

1. **Dynamic skill injection** — skill descriptions are injected into the LLM
   context at each turn from the current `ResourceStore`, rather than being
   baked into `state.system_prompt` at agent start time.

2. **File watcher** — watches `.planck/skills/`, `.planck/teams/`, and
   `config.json` for changes and calls `ResourceStore.reload/0` automatically.

Together these give running agents live access to updated skills and config
without restarting.

---

## 1. Dynamic skill injection

### Behaviour

`AgentSpec` stores the resolved skill **names** rather than baking descriptions
into `state.context.system_prompt`. At session start, `planck_headless` passes
`skill_pool:`, `ranked_skill_names:`, `top_skills:`, `skill_names:`,
`skill_refresh_fn:`, and `skill_index_refresh_fn:` in start opts, which
`Context.build/1` stores as `skills_pool` etc.

#### System prompt — frozen pool

The skill section shown in the system prompt is built from `Context.skills_pool`,
which is **frozen at session start**. It is only rebuilt after context compaction
(via `skills_index_refresh_fn`). This design keeps system prompt tokens stable
and predictable across turns — the LLM sees the same index every call within a
compaction window, which is cache-friendly.

`Context.skills_pool` is **not** updated when `ResourceStore.reload/0` fires during
a live session. In-flight sessions see the skill pool they were started with in
their system prompt.

#### Tools — live pool

`Context.skills_refresh_fn` (`(-> [Skill.t()]) | nil`) is used exclusively by the
`load_skill` and `list_skills` tools. It calls `fn -> ResourceStore.get().skills end`
at tool-call time, so agents always access the current, live pool when loading a
skill on demand — even if a skill was added after the session started.

#### Effect summary

- Skill file edits on disk are picked up by the `Watcher`, which calls
  `ResourceStore.reload/0`. The live pool (used by tools) is updated immediately.
  The system prompt index (frozen pool) is updated only on the next compaction.
- New skills added to the pool after a session starts are loadable via `load_skill`
  by name, even without appearing in the system prompt index.
- `state.context.system_prompt` is the *base* prompt only (identity line + user-written
  prompt). The skill index is assembled separately and prepended each LLM call.

### Migration

`assemble_system_prompt` no longer appends skills. It returns the base prompt
only. `AgentSpec.to_start_opts/2` accepts `skill_pool:`, `ranked_skill_names:`,
`top_skills:`, `skill_names:`, `skill_refresh_fn:`, and
`skill_index_refresh_fn:` start opts built by `planck_headless`. `Context`
gains `skills_pool` / `skills_ranked` / `skills_top_n` / `skills_names` /
`skills_refresh_fn` / `skills_index_refresh_fn` replacing the former
`skill_names`, `skill_pool`, `skill_refresh_fn`, and related fields.

---

## 2. File watcher

### Watched paths

| Path | Triggers |
|---|---|
| `.planck/skills/**/*.md` | Skill content changed |
| `~/.planck/skills/**/*.md` | Global skill content changed |
| `.planck/teams/**/*.json` | Team definition changed |
| `.planck/config.json` | Model config changed |
| `.planck/.env` | API keys changed |
| `~/.planck/.env` | Global API keys changed |

### Implementation

A new `Planck.Headless.Watcher` GenServer started by
`Planck.Headless.AppSupervisor`. Uses the `file_system` Hex package
(`:file_system` OTP app) which wraps `inotify` (Linux), `FSEvents` (macOS),
and `ReadDirectoryChangesW` (Windows).

```elixir
defmodule Planck.Headless.Watcher do
  use GenServer

  @debounce_ms 300

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    dirs = watched_dirs()
    {:ok, watcher_pid} = FileSystem.start_link(dirs: dirs)
    FileSystem.subscribe(watcher_pid)
    {:ok, %{watcher: watcher_pid, timer: nil}}
  end

  def handle_info({:file_event, _pid, _event}, state) do
    # Debounce: cancel pending timer, start a new one
    if state.timer, do: Process.cancel_timer(state.timer)
    timer = Process.send_after(self(), :reload, @debounce_ms)
    {:noreply, %{state | timer: timer}}
  end

  def handle_info(:reload, state) do
    ResourceStore.reload()
    {:noreply, %{state | timer: nil}}
  end
end
```

A 300ms debounce prevents multiple rapid reloads when an editor writes several
files in quick succession.

### Startup condition

The watcher only starts if at least one watched directory exists on disk. If
none exist (e.g. a fresh install with no `.planck/` folder), it starts in a
no-op mode and rescans when `ResourceStore.reload/0` is called manually.

### Config hot-reload

`ResourceStore.reload/0` invalidates both the `JsonBinding` and `EnvBinding`
persistent-term caches **and** calls the Skogsra-generated `reload_*` function
for every JSON/env-backed config key (providers, models, default_model,
skills_dirs, etc.). This ensures that Skogsra's own per-key cache layer is
cleared, so `config.json` edits are reflected immediately without restarting.

The file watcher triggers this automatically on every save to a watched
directory, so API key changes in `.planck/.env` or config changes in
`.planck/config.json` take effect within 300 ms (the debounce window).

---

## What does NOT hot-reload

| Thing | Reason |
|---|---|
| Agent identity line (`You are X (type).`) | Baked into base `system_prompt` at start; requires agent restart |
| User-written system prompt (TEAM.json) | Same — part of base prompt |
| Tool closures for running agents | Closures capture runtime context; sidecar tools are managed separately by `SidecarManager` |
| Sidecar connection | Managed by `SidecarManager`; reconnects automatically on node-up |

---

## Dependencies

- `file_system` added to `planck_headless` deps (`:file_system` is the OTP
  app; available for Linux/macOS/Windows)

## Package ownership

- `Planck.Agent` — `do_run_llm` calls `build_system_prompt/1` which reads
  `state.context.skills_pool` (frozen) for the system prompt section each turn;
  `load_skill` / `list_skills` tools read `state.context.skills_refresh_fn` (live)
- `Planck.Agent.Context` — holds skill state; `skills_pool` (frozen),
  `skills_ranked` (SQLite order), `skills_top_n`, `skills_names`,
  `skills_refresh_fn`, and `skills_index_refresh_fn`;
  `refresh` rebuilds pool and ranked after compaction
- `Planck.Agent.AgentSpec` — `assemble_system_prompt` returns base prompt only;
  `to_start_opts` accepts `skill_pool:` etc. from callers
- `Planck.Headless` — passes skill start opts at session start:
  sets `skill_pool` from the current `ResourceStore.skills`, `ranked_skill_names` from
  `SkillUsage.ranked_names/5`, `top_skills` from `Config.top_skills!()`, and
  `skill_refresh_fn: fn -> ResourceStore.get().skills end`
- `Planck.Headless.Watcher` — GenServer; started by `AppSupervisor`
- `Planck.Headless.AppSupervisor` — starts `Watcher` under supervision
