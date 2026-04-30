defmodule Planck.Agent.ExternalTool do
  @moduledoc """
  Loads external tool definitions from `TOOL.json` files on the filesystem.

  Each external tool lives in its own subdirectory under a configured tools
  directory:

      <tools_dir>/
        check_complexity/
          TOOL.json
        run_linter/
          TOOL.json

  `TOOL.json` format:

      {
        "name":        "check_complexity",
        "description": "Check cyclomatic complexity of a file using radon.",
        "command":     "radon cc {{path}} -s",
        "parameters": {
          "type": "object",
          "properties": {
            "path": { "type": "string", "description": "File to analyse" }
          },
          "required": ["path"]
        }
      }

  `{{key}}` placeholders in `command` are replaced with the corresponding
  argument values at call time. Unknown placeholders are replaced with an empty
  string. `cwd` and `timeout` (milliseconds) can always be passed as runtime
  arguments in addition to the declared parameters.

  Commands run via `erlexec` — process groups are cleaned up on timeout or
  termination.

  ## Usage

      tools = Planck.Agent.ExternalTool.load_all(["~/.planck/tools"])

  Pass the returned `Tool.t()` structs alongside inter-agent tools when starting
  an agent or building the `grantable_tools` list for an orchestrator.
  """

  alias Planck.Agent.{BuiltinTools, Tool}

  @default_timeout 30_000

  @doc """
  Load all external tools from a list of directories.

  Each subdirectory containing a `TOOL.json` is loaded as a tool. Missing
  directories and malformed entries are silently skipped.
  """
  @spec load_all([Path.t()]) :: [Tool.t()]
  def load_all(dirs) do
    Enum.flat_map(dirs, &load_dir/1)
  end

  @doc """
  Load a single external tool from a `TOOL.json` file path.

  Returns `{:ok, tool}` or `{:error, reason}`.
  """
  @spec from_file(Path.t()) :: {:ok, Tool.t()} | {:error, String.t()}
  def from_file(path) do
    expanded = Path.expand(path)

    with {:ok, content} <- File.read(expanded),
         {:ok, data} <- Jason.decode(content),
         {:ok, tool} <- build_tool(data, path) do
      {:ok, tool}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, %Jason.DecodeError{} = e} ->
        {:error, "invalid JSON in #{path}: #{Exception.message(e)}"}

      {:error, posix} ->
        {:error, "cannot read #{path}: #{:file.format_error(posix)}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec load_dir(Path.t()) :: [Tool.t()]
  defp load_dir(dir) do
    expanded = Path.expand(dir)

    case File.ls(expanded) do
      {:error, _} -> []
      {:ok, entries} -> Enum.flat_map(entries, &load_entry(expanded, &1))
    end
  end

  @spec load_entry(Path.t(), String.t()) :: [Tool.t()]
  defp load_entry(dir, name) do
    path = Path.join([dir, name, "TOOL.json"])

    case from_file(path) do
      {:ok, tool} -> [tool]
      {:error, _} -> []
    end
  end

  @spec build_tool(map(), Path.t()) :: {:ok, Tool.t()} | {:error, String.t()}
  defp build_tool(spec, path)

  defp build_tool(
         %{
           "name" => name,
           "description" => desc,
           "command" => cmd,
           "parameters" => params
         },
         _path
       )
       when is_binary(name) and is_binary(desc) and is_binary(cmd) do
    template = cmd

    tool =
      Tool.new(
        name: name,
        description: desc,
        parameters: params,
        execute_fn: fn _id, args ->
          cwd = Map.get(args, "cwd", File.cwd!())
          timeout = Map.get(args, "timeout", @default_timeout)
          command = interpolate(template, args)
          BuiltinTools.run_bash(command, timeout, cwd)
        end
      )

    {:ok, tool}
  end

  defp build_tool(data, path) do
    required = ["name", "description", "command", "parameters"]
    missing = Enum.reject(required, &Map.has_key?(data, &1))
    {:error, "TOOL.json at #{path} missing required fields: #{Enum.join(missing, ", ")}"}
  end

  @spec interpolate(String.t(), map()) :: String.t()
  defp interpolate(template, args) do
    Regex.replace(~r/\{\{(\w+)\}\}/, template, fn _, key ->
      to_string(Map.get(args, key, ""))
    end)
  end
end
