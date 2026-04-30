# Changelog

## v0.1.0

### Inter-agent tools — orchestrator improvements

- `orchestrator_tools/6` — added `grantable_skills` parameter; orchestrators
  can now grant skills to dynamically spawned workers via `spawn_agent`.
- `start_orchestrator` passes `store.skills` as `grantable_skills` so all
  available skills are grantable by default.
- `start_workers` and `start_dynamic_worker` pass the worker's own id as
  `own_id` to `worker_tools/4` for deadlock detection in `ask_agent`.
- `list_models` tool now includes `base_url` in its output so the LLM can
  pass the correct base_url when calling `spawn_agent` for non-default servers.

### Session — agent usage persistence

- `start_orchestrator` and `start_workers` read `agent_usage:#{id}` from
  session metadata and pass `:usage` and `:cost` init options to each agent so
  token counts and cost are restored on session resume.

### Skills — `list_skills` opt-in tool

- `list_skills` tool added to the agent tool pool when skills are available.
  Agents that need autonomous skill discovery declare `"list_skills"` in their
  TEAM.json `"tools"` array. `load_skill` is injected automatically by
  `AgentSpec.to_start_opts/2` and does not need to be declared.

### Prior entries

First release.

- `Planck.Headless.SidecarManager` — manages the optional sidecar OTP
  application: builds (`mix deps.get` + `mix compile`), spawns via erlexec
  (`elixir --sname planck_sidecar --cookie <cookie> -S mix run --no-halt`),
  monitors node connections, auto-discovers the entry module via
  `Planck.Agent.Sidecar.discover/0` RPC on nodeup, wraps tools with RPC
  `execute_fn` closures, stores in `ResourceStore`; clears on nodedown; forwards
  `PATH`, `MIX_ENV`, `PLANCK_LOCAL` from the parent environment; PubSub events
  on `"planck:sidecar"` topic; `subscribe/0` / `unsubscribe/0` API
- `ResourceStore.put_tools/1` and `clear_tools/0` — called by `SidecarManager`
  to sync sidecar tools
- `Config.sidecar` (`PLANCK_SIDECAR`) — path to the sidecar Mix project directory
- Removed `Config.tools_dirs`, `Config.compactor`, `ResourceStore.on_compact`;
  per-agent compactors via `AgentSpec.compactor` and `Compactor.build/2`
- `Config.JsonBinding.init/1` returns `:error` (not `{:ok, %{}}`) when
  `skip_json_config: true` — Skogsra skips the binding without emitting warnings

### Edit-message support

- `Headless.rewind_to_message/3` — truncates the session to strictly before the
  given DB row id (`Session.truncate_after/2`), rewinds the orchestrator's
  in-memory history to before that same id (`Agent.rewind_to_message/2`, since
  `Message.id == db_id` for persisted messages), then re-prompts with `new_text`;
  powers the edit-message UI feature

### Session lifecycle

- `Planck.Headless.start_session/1` — resolves team (alias, path, or nil for
  the default dynamic team), generates a `<adjective>-<noun>` session name,
  starts `Planck.Agent.Session`, materialises agents with built-in + external
  tools and resolved skills, saves metadata (`team_id`, `team_alias`, `cwd`,
  `session_name`) to SQLite.
- `Planck.Headless.resume_session/1` — accepts session id or name, reopens the
  SQLite session, reconstructs the base team from metadata, replays completed
  `spawn_agent` calls from the previous orchestrator's history to restore
  dynamically-added workers (deduped by `{type, name}` against the base team,
  so two builders "Bob" and "Charlie" are both correctly reconstructed),
  detects in-flight `ask_agent` and unfinished workers, injects a recovery
  context message under the new orchestrator if anything was in-flight.
- `Planck.Headless.close_session/1` — stops all agents by `team_id`, stops the
  Session GenServer; SQLite file retained.
- `Planck.Headless.prompt/2` — dispatches to the orchestrator via the agent
  registry (`team_id` is read from session metadata; no separate tracker).
- `Planck.Headless.list_sessions/0` — globs sessions dir for `<id>_<name>.db`
  files; checks `Session.whereis/1` for active status.
- `Planck.Headless.list_teams/0`, `get_team/1` — wrap `ResourceStore`.
- `Planck.Headless.available_models/0`, `reload_resources/0`.

### Team materialization

- Orchestrators receive all four `BuiltinTools` (read, write, edit, bash) in
  their `tool_pool` so spec.tools names like `"read"` resolve correctly.
- `orchestrator_tools` + `worker_tools` injected on top of resolved spec tools;
  workers get `worker_tools` only (no spawn_agent etc.).
- Default dynamic team: orchestrator's `base_url` pulled from
  `ResourceStore.available_models` so local servers use the correct URL.

### Config

- `Planck.Headless.Config.JsonBinding` — Skogsra `Binding` that reads
  `~/.planck/config.json` and `.planck/config.json` at resolution time; results
  cached in persistent_term; `invalidate/0` for cache busting before reload.
- `config_files` app_env (`PLANCK_CONFIG_FILES`) — controls which JSON files
  are read; `config :planck_headless, :skip_json_config, true` for tests.
- `models` app_env — `Planck.AI.Config`-format model declarations parsed to
  `[Planck.AI.Model.t()]`; replaces `local_servers`; no network at boot.
- Provider atoms pre-loaded at boot via `Planck.AI.Model.providers()` to avoid
  `String.to_existing_atom` failures on lazy module load.
- `PathList` inline as `Planck.Headless.Config.PathList` submodule.

### ResourceStore

- Cloud models: static LLMDB catalog filtered by API key presence.
- Local/custom models: from `Config.models!()` — already parsed, zero network.
- `AppSupervisor` owns `ResourceStore`; no `SessionRegistry` — dropped in
  favour of reading `team_id` directly from session SQLite metadata.

### Session naming

- `Planck.Headless.SessionName` — generates `<adjective>-<noun>` names;
  `generate/1` retries on collision; `sanitize/1` normalises to `[a-z0-9-]+`.
- Session files stored as `<sessions_dir>/<id>_<name>.db`;
  `Session.find_by_id/2` and `find_by_name/2` use glob for O(1) lookup.

### Other

- `Planck.Headless.DefaultPrompt` — default system prompt for dynamic-team
  orchestrator.
- `Mox` in test deps; `Planck.Agent.MockAI` wired in test.exs.
- `start_session(template: alias)` exercised via ResourceStore in tests.
- Fixed in-flight detection and completed spawn_agent matching to use
  `MapSet.member?/2` instead of `is_map_key/2` guard (MapSet is a struct,
  not a plain map; the guard silently never matched).

### Session resume improvements

- Stable agent IDs across session resumes: `save_metadata` now persists an `agent_ids`
  map (name→id JSON) and `resume_session` loads it, passing previous IDs to
  `materialize_team`, `start_workers`, and `start_dynamic_worker` so processes restart
  with the same IDs they had in the original session
- `maybe_inject_recovery` simplified: no longer needs `find_previous_orchestrator` since
  IDs are stable across resumes

### Worker lifecycle

- `unfinished_workers` rewrite: uses `worker_unfinished?/1` — a worker is considered
  unfinished when their most recent `:user` message (last assigned task) has no
  `send_response` in any assistant message that follows it
- `send_response` sender attribution threaded through: `start_workers` and
  `start_dynamic_worker` now build a `sender = %{id, name}` map and pass it to
  `worker_tools/3`, so every response reaches the orchestrator with full sender metadata
