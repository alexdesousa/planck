# Local Node Tools

## Overview

Allow apps depending on `planck_headless` to register custom tools that run in
the same BEAM node without a sidecar. Tools run with zero RPC overhead; their
`execute_fn` closures are called directly in the host process.

Two levels of scope:

- **Global** — `Planck.Headless.register_tool/1` adds a tool to `ResourceStore`.
  Available to all new sessions for the lifetime of the node.
- **Per-session** — `start_session(tools: [...])` passes extra tools for a
  single session only.

## Tool pool ordering

The full tool pool an agent resolves names against is built as:

```
builtins() ++ store.tools ++ store.registered_tools ++ session_tools
```

Later entries shadow earlier ones by name (via `Map.new`). This means:

| Priority (highest → lowest) | Source |
|---|---|
| 1 | Per-session tools (`start_session(tools: [...])`) |
| 2 | Registered tools (`register_tool/1`) |
| 3 | Sidecar tools |
| 4 | Built-ins |

An app registering a no-op `"bash"` shadows the built-in for all sessions. A
per-session `"bash"` shadows even the registered one. See `docs/guides/tool-shadowing.md`.

## ResourceStore changes

New field `registered_tools: [Tool.t()]` (default `[]`), separate from `tools`
(sidecar-owned). `put_tools/1` and `clear_tools/0` only affect `tools`; they
never touch `registered_tools`.

New callbacks:

```elixir
@spec register_tool(Tool.t()) :: :ok
def register_tool(tool)

@spec unregister_tool(String.t()) :: :ok
def unregister_tool(name)
```

`register_tool/1` appends (or replaces by name if already registered).
`unregister_tool/1` removes by name; no-op if not found.

## Headless API

```elixir
@doc "Register a tool globally. Available to all new sessions."
@spec register_tool(Planck.Agent.Tool.t()) :: :ok
def register_tool(tool)

@doc "Remove a globally registered tool by name."
@spec unregister_tool(String.t()) :: :ok
def unregister_tool(name)
```

`start_session/1` accepts a new `tools:` option:

```elixir
{:ok, sid} = Planck.Headless.start_session(
  template: "my-team",
  tools: [my_custom_tool]
)
```

Per-session tools are passed directly into the `tool_pool` for that session.
They are not stored in `ResourceStore`.

## materialize_team changes

All places that build `tool_pool` update from:

```elixir
tool_pool: builtins() ++ store.tools
```

to:

```elixir
tool_pool: builtins() ++ store.tools ++ store.registered_tools ++ session_tools
```

where `session_tools` comes from `Keyword.get(opts, :tools, [])` passed into
`materialize_team`.

`start_session` and `resume_session` pass their `tools:` opt through to
`materialize_team`.

## Example

```elixir
# application.ex — register at boot
def start(_type, _args) do
  Planck.Headless.register_tool(MyApp.Tools.query_db())
  Planck.Headless.register_tool(MyApp.Tools.send_notification())
  ...
end

# Disable bash globally
Planck.Headless.register_tool(
  Planck.Agent.Tool.new(
    name: "bash",
    description: "Shell execution is disabled.",
    parameters: %{"type" => "object", "properties" => %{}},
    execute_fn: fn _agent_id, _id, _args -> {:error, "bash is disabled"} end
  )
)

# Per-session tool
{:ok, sid} = Planck.Headless.start_session(
  tools: [MyApp.Tools.session_context(user_id)]
)
```

## Package ownership

- `Planck.Headless.ResourceStore` — `registered_tools` field; `register_tool/1`;
  `unregister_tool/1`
- `Planck.Headless` — `register_tool/1`; `unregister_tool/1`; `start_session`
  `tools:` opt; `materialize_team` updated tool_pool
