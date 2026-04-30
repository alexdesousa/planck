defmodule Planck.Agent.BuiltinTools do
  @moduledoc """
  Factory functions for the four built-in tools: `read`, `write`, `edit`, `bash`.

  These tools cover file system access and shell execution. Together they are
  sufficient for most agent tasks — reading context, writing code, applying
  edits, and running scripts (including skill scripts).

  Shell execution uses `erlexec` (`:exec`) which manages process groups and
  cleans up child processes on timeout or termination.

  ## Usage

      tools = [
        Planck.Agent.BuiltinTools.read(),
        Planck.Agent.BuiltinTools.write(),
        Planck.Agent.BuiltinTools.edit(),
        Planck.Agent.BuiltinTools.bash()
      ]

  Pass these alongside any inter-agent tools when starting an agent.
  """

  alias Planck.Agent.Tool

  @default_bash_timeout 30_000

  @doc """
  Returns the `read` tool — reads the contents of a file from disk.

  Supports optional `offset` (lines to skip from the start) and `limit`
  (maximum number of lines to return) for reading large files in chunks.
  Uses line-by-line streaming so only the requested portion is loaded.
  """
  @spec read() :: Tool.t()
  def read do
    Tool.new(
      name: "read",
      description: """
      Read the contents of a file. Use offset and limit to read large files
      in chunks without loading the entire file into memory.
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Path to the file"},
          "offset" => %{
            "type" => "integer",
            "description" => "Number of lines to skip from the start (default: 0)"
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of lines to return (default: all)"
          }
        },
        "required" => ["path"]
      },
      execute_fn: fn _id, args ->
        path = args["path"]
        offset = Map.get(args, "offset", 0)
        limit = Map.get(args, "limit")

        path
        |> Path.expand()
        |> read_lines(path, offset, limit)
      end
    )
  end

  @doc """
  Returns the `write` tool — writes content to a file.

  Creates the file and any missing parent directories. Overwrites if the file
  already exists.
  """
  @spec write() :: Tool.t()
  def write do
    Tool.new(
      name: "write",
      description:
        "Write content to a file, creating the file and any missing parent directories.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Path to the file"},
          "content" => %{"type" => "string", "description" => "Content to write"}
        },
        "required" => ["path", "content"]
      },
      execute_fn: fn _id, %{"path" => path, "content" => content} ->
        expanded = Path.expand(path)
        dirname = Path.dirname(expanded)

        with :ok <- File.mkdir_p(dirname),
             :ok <- File.write(expanded, content) do
          {:ok, "Written #{path}."}
        else
          {:error, reason} ->
            reason = "cannot write #{path}: #{:file.format_error(reason)}"
            {:error, reason}
        end
      end
    )
  end

  @doc """
  Returns the `edit` tool — replaces an exact string in a file.

  Fails if `old_string` is not found or appears more than once. Make
  `old_string` long enough to be unique in the file.
  """
  @spec edit() :: Tool.t()
  def edit do
    Tool.new(
      name: "edit",
      description: """
      Replace an exact string in a file. Fails if old_string is not found or
      appears more than once — include enough surrounding context to make it unique.
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Path to the file"},
          "old_string" => %{
            "type" => "string",
            "description" => "Exact string to replace (must be unique in the file)"
          },
          "new_string" => %{"type" => "string", "description" => "Replacement string"}
        },
        "required" => ["path", "old_string", "new_string"]
      },
      execute_fn: fn _id, %{"path" => path, "old_string" => old, "new_string" => new} ->
        expanded = Path.expand(path)

        with {:ok, content} <- File.read(expanded),
             {:ok, before, rest} <- split_unique(content, old, path),
             :ok <- File.write(expanded, before <> new <> rest) do
          {:ok, "Edited #{path}."}
        else
          {:error, reason} when is_binary(reason) -> {:error, reason}
          {:error, posix} -> {:error, "cannot access #{path}: #{:file.format_error(posix)}"}
        end
      end
    )
  end

  @doc """
  Returns the `bash` tool — runs a shell command via `erlexec`.

  Process groups are cleaned up on timeout or termination. Both stdout and
  stderr are captured; stderr is appended to the output when non-empty.

  `cwd` and `timeout` are optional tool arguments supplied by the caller at
  runtime — they are not baked into the tool at construction time.
  """
  @spec bash() :: Tool.t()
  def bash do
    Tool.new(
      name: "bash",
      description: "Run a shell command and return its output (stdout + stderr).",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "command" => %{"type" => "string", "description" => "The shell command to run"},
          "cwd" => %{
            "type" => "string",
            "description" => "Working directory (default: current directory)"
          },
          "timeout" => %{
            "type" => "integer",
            "description" => "Timeout in milliseconds (default: #{@default_bash_timeout})"
          }
        },
        "required" => ["command"]
      },
      execute_fn: fn _id, args ->
        cmd = args["command"]
        cwd = Map.get(args, "cwd", File.cwd!())
        timeout = Map.get(args, "timeout", @default_bash_timeout)
        run_bash(cmd, timeout, cwd)
      end
    )
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec read_lines(Path.t(), Path.t(), non_neg_integer(), pos_integer() | nil) ::
          {:ok, String.t()}
          | {:error, String.t()}
  defp read_lines(expanded, display_path, offset, limit)

  defp read_lines(expanded, display_path, offset, limit)
       when is_binary(expanded) and is_binary(display_path) and offset >= 0 do
    stream =
      expanded
      |> File.stream!(:line)
      |> Stream.drop(offset)

    stream =
      if limit,
        do: Stream.take(stream, limit),
        else: stream

    lines =
      stream
      |> Enum.to_list()
      |> IO.iodata_to_binary()

    {:ok, lines}
  rescue
    e in File.Error ->
      reason = "cannot read #{display_path}: #{:file.format_error(e.reason)}"
      {:error, reason}
  end

  @spec split_unique(String.t(), String.t(), Path.t()) ::
          {:ok, String.t(), String.t()} | {:error, String.t()}
  defp split_unique(content, old, path) do
    case String.split(content, old, parts: 3) do
      [before, rest] ->
        {:ok, before, rest}

      [_] ->
        reason = "old_string not found in #{path}"
        {:error, reason}

      _ ->
        reason = "old_string appears more than once in #{path} — make it more specific"
        {:error, reason}
    end
  end

  @doc false
  @spec run_bash(String.t(), pos_integer(), Path.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def run_bash(command, timeout, cwd) do
    exec_opts = [:sync, :stdout, :stderr, {:cd, String.to_charlist(cwd)}]
    task = Task.async(fn -> :exec.run(command, exec_opts) end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> decode_exec_result(result)
      {:exit, reason} -> {:error, "Process failed: #{inspect(reason)}"}
      nil -> {:error, "Process timed out after #{timeout}ms"}
    end
  end

  @spec decode_exec_result({:ok, term()} | {:error, term()}) ::
          {:ok, String.t()}
          | {:error, String.t()}
  defp decode_exec_result(result)

  defp decode_exec_result({:ok, result}) do
    stdout = result[:stdout] || []
    stderr = result[:stderr] || []

    {:ok, assemble(stdout, stderr)}
  end

  defp decode_exec_result({:error, result}) when is_list(result) do
    raw = result[:exit_status] || 256
    status = decode_exit_status(raw)
    stdout = result[:stdout] || []
    stderr = result[:stderr] || []
    reason = "Process exited with status #{status}\n#{assemble(stdout, stderr)}"

    {:error, reason}
  end

  defp decode_exec_result({:error, reason}) do
    {:error, "failed to start process: #{inspect(reason)}"}
  end

  @spec decode_exit_status(integer()) :: integer()
  defp decode_exit_status(raw)
  defp decode_exit_status(raw) when rem(raw, 256) == 0, do: div(raw, 256)
  defp decode_exit_status(raw), do: raw

  @spec assemble([iodata()], [iodata()]) :: String.t()
  defp assemble(stdout, stderr) do
    s = IO.iodata_to_binary(stdout)
    e = IO.iodata_to_binary(stderr)
    if e == "", do: s, else: s <> "\nSTDERR:\n" <> e
  end
end
