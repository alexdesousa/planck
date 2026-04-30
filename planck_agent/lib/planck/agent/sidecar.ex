defmodule Planck.Agent.Sidecar do
  @moduledoc """
  Behaviour and utilities for sidecar applications that extend planck_headless
  over distributed Erlang.

  ## Behaviour

  A sidecar entry-point module implements one required callback:

  - `tools/0` — returns `[Planck.Agent.Tool.t()]` with full `execute_fn` closures.
    These run **locally on the sidecar node**.

  ## Module-level utilities

  `Planck.Agent.Sidecar` itself provides two public functions that planck_headless
  calls on the sidecar node via `:rpc.call/5`, passing the sidecar module as an
  argument. Because `planck_agent` is a dependency of both planck_headless and the
  sidecar, the module is available on both nodes:

  - `list_tools/1` — converts `module.tools()` to `[Planck.AI.Tool.t()]` (no
    closures, serialisable across nodes).
  - `execute_tool/4` — finds a tool by name in `module.tools()` and calls its
    `execute_fn` locally on the sidecar.

  planck_headless calls:

      :rpc.call(sidecar_node, Planck.Agent.Sidecar, :list_tools, [MySidecar.Planck])
      :rpc.call(sidecar_node, Planck.Agent.Sidecar, :execute_tool,
                [MySidecar.Planck, tool_name, agent_id, args], timeout)

  ## Minimal example

      defmodule MySidecar.Planck do
        use Planck.Agent.Sidecar

        @impl true
        def tools do
          [
            Planck.Agent.Tool.new(
              name: "run_tests",
              description: "Run the test suite. Pass timeout_ms to override the default.",
              parameters: %{
                "type" => "object",
                "properties" => %{
                  "timeout_ms" => %{
                    "type" => "integer",
                    "description" => "Max milliseconds to wait (default 120000)"
                  }
                }
              },
              execute_fn: fn _id, args ->
                timeout = Map.get(args, "timeout_ms", 120_000)
                case System.cmd("mix", ["test"], timeout: timeout) do
                  {output, 0} -> {:ok, output}
                  {output, _} -> {:error, output}
                end
              end
            )
          ]
        end
      end

  See `specs/sidecar.md` for the full design.
  """

  @doc """
  Return the sidecar's tools as `Planck.Agent.Tool` structs (with `execute_fn`).

  This is the only required callback. `execute_fn` closures run **locally on the
  sidecar node** — they are never serialised or called on planck_headless.

  Each tool should accept an optional `"timeout_ms"` argument in its parameter
  schema so the AI can hint at how long to wait for the tool call.
  """
  @callback tools() :: [Planck.Agent.Tool.t()]

  @doc """
  Convenience macro for implementing the `Planck.Agent.Sidecar` behaviour.

  `use Planck.Agent.Sidecar` injects:

  - `@behaviour Planck.Agent.Sidecar` — marks the module as a sidecar entry point.
  - A default `tools/0` returning `[]` — override this to provide tools.

  ## Usage

      defmodule MySidecar.Planck do
        use Planck.Agent.Sidecar

        @impl true
        def tools do
          [
            Planck.Agent.Tool.new(
              name: "run_tests",
              description: "Run the test suite.",
              parameters: %{"type" => "object", "properties" => %{}},
              execute_fn: fn _id, _args ->
                {out, 0} = System.cmd("mix", ["test"])
                {:ok, out}
              end
            )
          ]
        end
      end

  The `tools/0` function is the only thing you normally need to override.
  `list_tools/1` and `execute_tool/4` are **not** injected here — they are
  module-level functions on `Planck.Agent.Sidecar` itself that planck_headless
  calls on the sidecar node passing your module as an argument:

      :rpc.call(node, Planck.Agent.Sidecar, :list_tools, [MySidecar.Planck])
      :rpc.call(node, Planck.Agent.Sidecar, :execute_tool,
                [MySidecar.Planck, tool_name, agent_id, args], timeout)

  This design keeps the dispatch logic in `planck_agent` (available on both
  nodes) rather than requiring each sidecar module to implement it.
  """
  defmacro __using__(_options) do
    quote do
      @behaviour Planck.Agent.Sidecar

      @impl Planck.Agent.Sidecar
      def tools, do: []

      defoverridable tools: 0
    end
  end

  # ---------------------------------------------------------------------------
  # Module-level utilities called via :rpc.call on the sidecar node
  # ---------------------------------------------------------------------------

  @doc """
  Convert `module.tools()` to `[Planck.AI.Tool.t()]` — serialisable, no closures.

  Called by planck_headless on the sidecar node:

      :rpc.call(sidecar_node, Planck.Agent.Sidecar, :list_tools, [MySidecar.Planck])
  """
  @spec list_tools(module()) :: [Planck.AI.Tool.t()]
  def list_tools(module) do
    Enum.map(module.tools(), fn tool ->
      Planck.AI.Tool.new(
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters
      )
    end)
  end

  @doc """
  Execute a named tool via the sidecar module's `tools/0` list.

  Called by planck_headless on the sidecar node:

      :rpc.call(sidecar_node, Planck.Agent.Sidecar, :execute_tool,
                [MySidecar.Planck, tool_name, agent_id, args], timeout)

  The `timeout` is read from `args["timeout_ms"]` by the planck_headless RPC
  wrapper, not by this function.
  """
  @spec execute_tool(module(), String.t(), String.t(), map()) ::
          {:ok, term()} | {:error, term()}
  def execute_tool(module, tool_name, agent_id, args) do
    case Enum.find(module.tools(), &(&1.name == tool_name)) do
      nil -> {:error, "unknown tool: #{tool_name}"}
      tool -> tool.execute_fn.(agent_id, args)
    end
  end
end
