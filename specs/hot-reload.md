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
into `state.system_prompt`. At session start, `planck_headless` builds a
`%Planck.Agent.SkillIndex{}` and passes it to the agent as `skills:` in start opts.

#### System prompt — frozen pool

The skill section shown in the system prompt is built from `SkillIndex.pool`,
which is **frozen at session start**. It is only rebuilt after context compaction
(via `SkillIndex.index_refresh_fn`). This design keeps system prompt tokens stable
and predictable across turns — the LLM sees the same index every call within a
compaction window, which is cache-friendly.

`SkillIndex.pool` is **not** updated when `ResourceStore.reload/0` fires during
a live session. In-flight sessions see the skill pool they were started with in
their system prompt.

#### Tools — live pool

`SkillIndex.refresh_fn` (`(-> [Skill.t()]) | nil`) is used exclusively by the
`load_skill` and `list_skills` tools. It calls `fn -> ResourceStore.get().skills end`
at tool-call time, so agents always access the current, live pool when loading a
skill on demand — even if a skill was added after the session started.

#### Effect summary

- Skill file edits on disk are picked up by the `Watcher`, which calls
  `ResourceStore.reload/0`. The live pool (used by tools) is updated immediately.
  The system prompt index (frozen pool) is updated only on the next compaction.
- New skills added to the pool after a session starts are loadable via `load_skill`
  by name, even without appearing in the system prompt index.
- `state.system_prompt` is the *base* prompt only (identity line + user-written
  prompt). The skill index is assembled separately and prepended each LLM call.

### Migration

`assemble_system_prompt` no longer appends skills. It returns the base prompt
only. `AgentSpec.to_start_opts/2` accepts a `skills:` start opt (`%SkillIndex{}`
or keyword-compatible opts) built by `planck_headless`. `Agent` state gains
`skills: %SkillIndex{}` replacing the former `skill_names`, `skill_pool`,
`skill_refresh_fn`, and related fields.

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

`ResourceStore.reload/0` already calls `Config.reload_*` for API keys and
refreshes available models. The file watcher triggers it automatically, so
API key changes in `.planck/.env` take effect on the next LLM turn without
any manual action.

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
  `state.skills.pool` (frozen) for the system prompt section each turn;
  `load_skill` / `list_skills` tools read `state.skills.refresh_fn` (live)
- `Planck.Agent.SkillIndex` — new struct consolidating all skill state; holds
  `pool` (frozen), `ranked` (SQLite order), `top_n`, `names`, `refresh_fn`,
  and `index_refresh_fn`; `refresh/1` rebuilds pool and ranked after compaction
- `Planck.Agent.AgentSpec` — `assemble_system_prompt` returns base prompt only;
  `to_start_opts` accepts `skills: %SkillIndex{}` from callers
- `Planck.Headless` — builds `%SkillIndex{}` at session start:
  sets `pool` from the current `ResourceStore.skills`, `ranked` from
  `SkillUsage.ranked_names/5`, `top_n` from `Config.top_skills!()`, and
  `refresh_fn: fn -> ResourceStore.get().skills end`
- `Planck.Headless.Watcher` — GenServer; started by `AppSupervisor`
- `Planck.Headless.AppSupervisor` — starts `Watcher` under supervision
