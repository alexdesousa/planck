# Tool Shadowing

When Planck builds the tool pool for an agent, it resolves names against a list
ordered as:

```
builtins() ++ registered_tools ++ sidecar_tools
```

If two tools share the same name, the **last one wins**. This means any tool
you register — via `Planck.Headless.register_tool/1` or a sidecar — will
automatically shadow a built-in of the same name for any agent that declares it
in their `"tools"` array.

This is an intentional contract, not an implementation detail.

## Security use case — disabling a built-in

You can replace a built-in with a no-op to prevent agents from using it:

```elixir
no_bash = Planck.Agent.Tool.new(
  name: "bash",
  description: "Shell execution is disabled in this environment.",
  parameters: %{"type" => "object", "properties" => %{}},
  execute_fn: fn _agent_id, _id, _args ->
    {:error, "bash is disabled. Use the provided tools instead."}
  end
)

Planck.Headless.register_tool(no_bash)
```

Any agent that declares `"bash"` in their `TEAM.json` tools list now receives
the no-op instead of the real shell executor. Agents that don't declare `"bash"`
are unaffected.

The same pattern works for `read`, `write`, `edit`, or any other built-in.

## Custom implementation use case

You can replace a built-in with a sandboxed or augmented version:

```elixir
sandboxed_read = Planck.Agent.Tool.new(
  name: "read",
  description: "Read a file. Only files under /workspace are accessible.",
  parameters: %{
    "type" => "object",
    "properties" => %{
      "path" => %{"type" => "string", "description" => "File path to read"}
    },
    "required" => ["path"]
  },
  execute_fn: fn _agent_id, _id, %{"path" => path} ->
    expanded = Path.expand(path)
    if String.starts_with?(expanded, "/workspace") do
      case File.read(expanded) do
        {:ok, content} -> {:ok, content}
        {:error, reason} -> {:error, "Could not read file: #{reason}"}
      end
    else
      {:error, "Access denied: only files under /workspace are readable."}
    end
  end
)

Planck.Headless.register_tool(sandboxed_read)
```

## Shadowing via sidecar

The same rule applies to sidecar tools. If your sidecar exposes a tool named
`"read"`, it shadows the built-in `read` for agents that declare it. This is
useful when your sidecar needs to intercept file reads to enforce logging,
encryption, or access control.

## Notes

- Shadowing is **name-based** — the tool's `name` field is the key.
- Agents only receive tools they explicitly declare in their `"tools"` array.
  Registering a shadow tool has no effect on agents that don't declare that name.
- The shadow applies **globally** to all sessions when using `register_tool/1`,
  or **per-session** when passed to `start_session/1`.
- To restore a built-in, remove the shadow registration and reload resources.
