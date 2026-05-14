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

### Current behaviour

`AgentSpec.to_start_opts/2` calls `assemble_system_prompt/2`, which resolves
the agent's declared skills and appends their descriptions to
`state.system_prompt`. The skill section is a static string — changes to
skill files on disk have no effect on running agents.

### New behaviour

`AgentSpec` stores the resolved skill **names** rather than their descriptions.
A new field `state.skill_names` (list of strings) replaces the baked-in skill
section in `state.system_prompt`.

At the start of each `do_run_llm` call, the private `build_system_prompt/1`
invokes `state.skill_refresh_fn.()` to get the current skill pool and appends
a fresh skill section to the base system prompt before building the `Context`:

```elixir
defp do_run_llm(state, turn_type) do
  system = build_system_prompt(state)   # calls skill_refresh_fn.() internally

  context = %Context{
    system: presence(system),
    messages: ...,
    tools: ...
  }
  ...
end
```

`build_system_prompt/1` resolves `state.skill_names` against the pool returned
by `skill_refresh_fn` and appends their descriptions, the same way
`assemble_system_prompt` did previously.

`skill_refresh_fn` is a `(-> [Skill.t()]) | nil` closure injected by the
caller (e.g. `planck_headless` passes `fn -> ResourceStore.get().skills end`).
This keeps `planck_agent` free of any dependency on `ResourceStore`.

### Effect

- If a skill file is updated on disk and `ResourceStore` is reloaded, the
  agent picks up the new description on its next turn with no restart.
- New skills added to the pool are available to agents that declare them by
  name, even if they were started before the skill existed.
- `state.system_prompt` becomes the *base* prompt only (identity line +
  user-written prompt). It no longer contains the skill section.

### Migration

`assemble_system_prompt` no longer appends skills. It returns the base prompt
only. `AgentSpec.to_start_opts/2` stores skill names in a `skill_names:` start
opt and accepts a `skill_refresh_fn:` override from callers. `Agent` state
gains `skill_names: [String.t()]` and `skill_refresh_fn: (-> [Skill.t()]) | nil`.

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

- `Planck.Agent` — adds `skill_names` and `skill_refresh_fn` fields;
  `do_run_llm` calls `build_system_prompt/1` which invokes `skill_refresh_fn`
  for a fresh skill section each turn
- `Planck.Agent.AgentSpec` — `assemble_system_prompt` returns base prompt only;
  `to_start_opts` returns `skill_names:` in start opts; accepts `skill_refresh_fn:`
  from callers
- `Planck.Headless` — passes `skill_refresh_fn: fn -> ResourceStore.get().skills end`
  to all `AgentSpec.to_start_opts/2` call sites
- `Planck.Headless.Watcher` — new GenServer; started by `AppSupervisor`
- `Planck.Headless.AppSupervisor` — starts `Watcher` under supervision
