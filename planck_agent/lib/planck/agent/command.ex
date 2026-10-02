defmodule Planck.Agent.Command do
  @moduledoc """
  Filesystem-based custom commands for slash-command dispatch.

  A command is a subdirectory under a commands directory (e.g.
  `.planck/commands/`) containing a `COMMAND.md` file. The file has YAML
  frontmatter with `name` and `description`, followed by an EEx template body
  that is rendered with the user's trailing arguments when the command is
  invoked via `/<command-name> [args]`.

  ## Directory layout

      .planck/commands/
      └── review-checklist/
          ├── COMMAND.md            ← required (frontmatter + EEx body)
          └── resources/            ← optional — files the agent may reference

  ## COMMAND.md format

      ---
      name: review-checklist
      description: Runs the project's review checklist against recent changes.
      disable-model-invocation: true
      help: "/review-checklist [scope]  — checks files in the given scope"
      ---

      # Review Checklist

      You are reviewing: <%= args %>

  Four fields are parsed from the frontmatter: `name`, `description`,
  `disable-model-invocation`, and `help`. The rest of the file is an EEx
  template stored raw and rendered on demand via `EExRenderer.render/2`.

  ## Usage

      commands = Planck.Agent.Command.load_all([".planck/commands", "~/.planck/commands"])

  The dispatcher in `Planck.Headless.prompt/3` resolves `/command-name [args]`
  against the loaded commands, renders the EEx body with `args: <trailing text>`,
  and enqueues a `{:custom, :command}` message.
  """

  require Logger

  @command_file "COMMAND.md"
  @frontmatter_re ~r/\A---\n(.*?)\n---/s

  @typedoc """
  A loaded custom command.

  - `:name` — identifier used in `/command-name` dispatch
  - `:description` — one-line summary shown in the UI dropdown
  - `:path` — absolute path to the command directory
  - `:command_file` — absolute path to `COMMAND.md`
  - `:disable_model_invocation` — when `true` (the default), the command is
    excluded from the agent's autonomous command pool. Has no effect in the
    user-only slash-command path; gates the follow-up `run_command` tool.
  - `:help` — usage string shown as the dropdown row subtitle; `nil` when absent
  - `:template` — the raw EEx body string (below the frontmatter), rendered
    on demand with the user's trailing arguments
  """
  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          path: Path.t(),
          command_file: Path.t(),
          disable_model_invocation: boolean(),
          help: String.t() | nil,
          template: String.t()
        }

  @enforce_keys [:name, :description, :path, :command_file, :template]
  defstruct [
    :name,
    :description,
    :path,
    :command_file,
    :template,
    disable_model_invocation: true,
    help: nil
  ]

  @doc """
  Load all commands from a list of directories.

  Each directory is scanned for subdirectories containing a `COMMAND.md` file.
  Directories that do not exist are silently skipped. Invalid `COMMAND.md`
  files are skipped with a warning.
  """
  @spec load_all([Path.t()]) :: [t()]
  def load_all(dirs) when is_list(dirs) do
    Enum.flat_map(dirs, &load_dir/1)
  end

  @doc """
  Load a single command from a `COMMAND.md` file path.

  Returns `{:ok, command}` or `{:error, reason}`.
  """
  @spec from_file(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def from_file(command_file) do
    with {:ok, content} <- read_file(command_file),
         {:ok, fields, template} <- parse_frontmatter(content, command_file) do
      {:ok,
       %__MODULE__{
         name: fields.name,
         description: fields.description,
         path: Path.dirname(command_file),
         command_file: command_file,
         disable_model_invocation: fields.disable_model_invocation,
         help: fields.help,
         template: template
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec load_dir(Path.t()) :: [t()]
  defp load_dir(dir) do
    expanded = Path.expand(dir)

    if File.dir?(expanded) do
      expanded |> File.ls!() |> Enum.flat_map(&load_entry(expanded, &1))
    else
      []
    end
  end

  @spec load_entry(Path.t(), String.t()) :: [t()]
  defp load_entry(dir, entry) do
    command_path = Path.join(dir, entry)
    command_file = Path.join(command_path, @command_file)

    if File.dir?(command_path) and File.regular?(command_file) do
      case from_file(command_file) do
        {:ok, command} ->
          [command]

        {:error, reason} ->
          Logger.warning("[Planck.Agent.Command] skipping #{command_file}: #{reason}")
          []
      end
    else
      []
    end
  end

  @spec read_file(Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  @spec parse_frontmatter(String.t(), Path.t()) ::
          {:ok, map(), String.t()} | {:error, String.t()}
  defp parse_frontmatter(content, path)
       when is_binary(content) and is_binary(path) do
    content = String.replace(content, "\r\n", "\n")

    case Regex.run(@frontmatter_re, content, capture: :all_but_first) do
      nil ->
        {:error, "#{path} has no frontmatter (expected --- ... --- at the top)"}

      [frontmatter] ->
        parse_yaml_fields(content, frontmatter, path)
    end
  end

  @spec parse_yaml_fields(String.t(), String.t(), Path.t()) ::
          {:ok, map(), String.t()}
          | {:error, String.t()}
  defp parse_yaml_fields(content, yaml, path)

  defp parse_yaml_fields(content, yaml, path) do
    Application.ensure_all_started(:yamerl)

    with [[_ | _] = pairs] <- :yamerl_constr.string(String.to_charlist(yaml)),
         {:ok, name} <- required_yaml_field(pairs, "name", path),
         {:ok, description} <- required_yaml_field(pairs, "description", path) do
      template = extract_template(content)
      disable_model_invocation = yaml_field(pairs, "disable-model-invocation")
      help = yaml_field(pairs, "help")

      fields =
        %{
          name: to_string(name),
          description: to_string(description),
          disable_model_invocation: disable_model_invocation != false,
          help: if(is_nil(help), do: nil, else: to_string(help))
        }

      {:ok, fields, template}
    else
      {:error, _} = error ->
        error

      _ ->
        {:error, "#{path}: frontmatter must be a YAML mapping"}
    end
  catch
    _, reason -> {:error, "#{path}: invalid YAML in frontmatter: #{inspect(reason)}"}
  end

  @spec required_yaml_field([{charlist(), term()}], String.t(), Path.t()) ::
          {:ok, term()}
          | {:error, String.t()}
  defp required_yaml_field(pairs, key, path)

  defp required_yaml_field(pairs, key, path) do
    if value = yaml_field(pairs, key) do
      {:ok, value}
    else
      {:error, "#{path}: missing required frontmatter field '#{key}'"}
    end
  end

  @spec yaml_field([{charlist(), term()}], String.t()) :: term()
  defp yaml_field(pairs, key) do
    charlist_key = String.to_charlist(key)

    case Enum.find(pairs, fn {k, _} -> k == charlist_key end) do
      {_, value} -> value
      nil -> nil
    end
  end

  @spec extract_template(String.t()) :: String.t()
  defp extract_template(content)

  defp extract_template(content) when is_binary(content) do
    [full] = Regex.run(@frontmatter_re, content, capture: :first)

    content
    |> String.slice(String.length(full), String.length(content))
    |> String.trim_leading("\n")
  end
end
