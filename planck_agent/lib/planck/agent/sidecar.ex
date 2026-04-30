defmodule Planck.Agent.Sidecar do
  @moduledoc """
  Behaviour and utilities for sidecar applications that extend planck_headless
  over distributed Erlang.

  ## Behaviour

  A sidecar entry-point module implements one required callback:

  - `tools/0` — returns `[Planck.Agent.Tool.t()]` with full `execute_fn` closures.
    These run **locally on the sidecar node**.

  ## Module-level utilities

  `Planck.Agent.Sidecar` itself provides module-level functions that
  planck_headless calls on the sidecar node via `:rpc.call/5`. Because
  `planck_agent` is a dependency of both planck_headless and the sidecar, these
  are available on both nodes:

  - `discover/0` — finds the module implementing this behaviour (cached in
    `:persistent_term` after the first call).
  - `list_tools/0` — discovers the entry module and returns its tools as
    `[Planck.AI.Tool.t()]` (no closures, serialisable across nodes).
  - `list_tools/1` — same but takes an explicit module; intended for tests.
  - `execute_tool/3` — discovers the entry module and executes a named tool.
  - `execute_tool/4` — same but takes an explicit module; intended for tests.

  planck_headless calls:

      :rpc.call(sidecar_node, Planck.Agent.Sidecar, :list_tools, [])
      :rpc.call(sidecar_node, Planck.Agent.Sidecar, :execute_tool,
                [tool_name, agent_id, args], timeout)

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
  `list_tools/0`, `discover/0`, `execute_tool/3`, and `execute_tool/4` are
  **not** injected here — they are module-level functions on
  `Planck.Agent.Sidecar` itself that planck_headless calls on the sidecar node:

      :rpc.call(node, Planck.Agent.Sidecar, :list_tools, [])
      :rpc.call(node, Planck.Agent.Sidecar, :execute_tool,
                [tool_name, agent_id, args], timeout)

  This design keeps the dispatch logic in `planck_agent` (available on both
  nodes) rather than requiring each sidecar module to implement it. No config
  is needed — `list_tools/0` discovers the entry module automatically via
  `discover/0`.
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
  Discover the module in the current node that implements `Planck.Agent.Sidecar`.

  Scans modules across all loaded OTP applications and returns the first one
  whose `@behaviour` attribute includes `Planck.Agent.Sidecar`, or `nil` if
  none is found. Only Elixir modules (names starting with `"Elixir."`) are
  checked; Erlang modules are skipped.

  Successful results are cached in `:persistent_term`. `nil` results are **not**
  cached — the next call will retry the scan, which is useful when the sidecar
  entry module is loaded after `discover/0` is first called.

  Called by planck_headless on the sidecar node via `list_tools/0`. You
  normally do not need to call this directly.
  """
  @spec discover() :: module() | nil
  def discover do
    sidecar_module_key = {__MODULE__, :entry_module}

    with :miss <- :persistent_term.get(sidecar_module_key, :miss),
         module when not is_nil(module) <- scan_entry_module() do
      :persistent_term.put(sidecar_module_key, module)
      module
    end
  end

  @spec elixir_module?(module()) :: boolean()
  defp elixir_module?(mod), do: mod |> Atom.to_string() |> String.starts_with?("Elixir.")

  @spec scan_entry_module() :: module() | nil
  defp scan_entry_module do
    :application.loaded_applications()
    |> Enum.flat_map(fn {app, _, _} ->
      case :application.get_key(app, :modules) do
        {:ok, mods} -> mods
        _ -> []
      end
    end)
    |> Enum.find(fn mod ->
      elixir_module?(mod) and
        :code.ensure_loaded(mod) == {:module, mod} and
        __MODULE__ in (mod.__info__(:attributes)[:behaviour] || [])
    end)
  end

  @doc """
  Discover the sidecar entry module and return its tools as `[Planck.AI.Tool.t()]`.

  Combines `discover/0` and `list_tools/1`. Returns `[]` if no entry module is
  found.

  Called by planck_headless on the sidecar node:

      :rpc.call(sidecar_node, Planck.Agent.Sidecar, :list_tools, [])
  """
  @spec list_tools() :: [Planck.AI.Tool.t()]
  def list_tools do
    case discover() do
      nil -> []
      module -> list_tools(module)
    end
  end

  @doc """
  Convert `module.tools()` to `[Planck.AI.Tool.t()]` — serialisable, no closures.
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
  Discover the entry module and execute a named tool.

  Called by planck_headless on the sidecar node:

      :rpc.call(sidecar_node, Planck.Agent.Sidecar, :execute_tool,
                [tool_name, agent_id, args], timeout)

  The `timeout` is read from `args["timeout_ms"]` by the planck_headless RPC
  wrapper, not by this function.
  """
  @spec execute_tool(String.t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def execute_tool(tool_name, agent_id, args) do
    case discover() do
      nil -> {:error, "no sidecar entry module found"}
      module -> execute_tool(module, tool_name, agent_id, args)
    end
  end

  @doc """
  Execute a named tool via an explicit sidecar module's `tools/0` list.

  Intended for tests. Production code should use `execute_tool/3`.
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
