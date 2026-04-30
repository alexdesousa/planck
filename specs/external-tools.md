# External Tools

> **Deprecated.** The `TOOL.json` / `tools_dirs` mechanism is replaced by the
> sidecar. External tools are now defined in a sidecar application that implements
> `Planck.Agent.Sidecar` and returns `[Tool.t()]` from `list_tools/0`.
> See `specs/sidecar.md`. The content below is kept for historical reference.

External tools extend the built-in `read`, `write`, `edit`, and `bash` tools
with CLI commands defined on the filesystem. They are loaded at startup by
`Planck.Agent.ExternalTool.load_all/1` and produce `Planck.Agent.Tool` structs
ready to be passed to any agent.

Tools that require external dependencies (Python packages, Node modules, etc.)
are best implemented as shell scripts — the `.exs` tool definition stays
dependency-free and delegates the heavy lifting to the script.

## Directory structure

```
<tools_dir>/
  check_complexity/
    TOOL.json
  run_linter/
    TOOL.json
```

Each subdirectory must contain a `TOOL.json` file. Subdirectories without one
are silently skipped. Missing directories are also skipped without error.

## TOOL.json format

```json
{
  "name":        "check_complexity",
  "description": "Check cyclomatic complexity of a file using radon.",
  "command":     "radon cc {{path}} -s",
  "parameters": {
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "Path to the file to analyse"
      }
    },
    "required": ["path"]
  }
}
```

All four top-level keys are required. `parameters` is a standard JSON Schema
object that the LLM uses to generate tool call arguments.

## Command interpolation

`{{key}}` placeholders in `command` are replaced with the matching argument
value at call time. Unknown placeholders are replaced with an empty string. The
interpolation is simple string substitution — quote arguments in the template
when values may contain spaces:

```json
"command": "mybin \"{{input}}\" --out {{output}}"
```

Two reserved arguments are always available regardless of the declared parameters:

| Argument  | Default                   | Description                        |
|-----------|---------------------------|------------------------------------|
| `cwd`     | current working directory | Working directory for the command  |
| `timeout` | `30000`                   | Timeout in milliseconds            |

## Execution

Commands run via `erlexec`. Both stdout and stderr are captured; stderr is
appended under a `STDERR:` header when non-empty. Process groups are cleaned up
on timeout or termination — no orphaned processes are left linked to the calling
agent's GenServer.

Exit status is decoded from the raw `waitpid()` value (`status * 256 → status`).

## Why external tools are not loaded automatically

`planck_agent` is a library — it does not run startup hooks or read config on
its own. Deciding which tools to load, which agents receive them, and whether
they go into `grantable_tools` or directly into a worker's tool list is an
application-level decision. That responsibility belongs to `planck_headless`,
which calls `ExternalTool.load_all/1` at startup and wires the results into
orchestrator and agent constructors.

## Configuration

| Env var                     | Config key    | Default                                      |
|-----------------------------|---------------|----------------------------------------------|
| `PLANCK_AGENT_TOOLS_DIRS`   | `:tools_dirs` | `.planck/tools:~/.planck/tools`              |

Colon-separated list of directories, expanded at runtime (`~` and relative paths
resolved). Configured via `Planck.Agent.Config.tools_dirs!/0`.

```elixir
config :planck_agent, :tools_dirs, [".planck/tools", "~/.planck/tools"]
```

## API

```elixir
# Load all tools from a list of directories; missing or malformed entries skipped.
@spec load_all([Path.t()]) :: [Planck.Agent.Tool.t()]

# Load a single tool from a TOOL.json file path.
@spec from_file(Path.t()) :: {:ok, Planck.Agent.Tool.t()} | {:error, String.t()}
```

## Integration with orchestrators

External tools can be included in the orchestrator's `grantable_tools` list so
the orchestrator can grant them to spawned workers via the `"tools"` argument:

```elixir
dirs     = Planck.Agent.Config.tools_dirs!()
ext      = Planck.Agent.ExternalTool.load_all(dirs)
builtin  = [Planck.Agent.BuiltinTools.read(), Planck.Agent.BuiltinTools.bash()]

orch_tools =
  Planck.Agent.Tools.orchestrator_tools(
    session_id, team_id, orch_id, models,
    builtin ++ ext
  ) ++ Planck.Agent.Tools.worker_tools(team_id, nil)
```

## Integration with teams

When starting agents from a `%Planck.Agent.Team{}`, pass external tools in the
`tools_by_type` map alongside built-in tools. The LLM knows their names and
descriptions from the `TOOL.json` files:

```elixir
tools_by_type = %{
  "analyst" => [Planck.Agent.BuiltinTools.read(), check_complexity_tool]
}
```
