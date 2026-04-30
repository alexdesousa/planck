defmodule Planck.Headless.Config do
  @moduledoc """
  Resolved runtime configuration for `planck_headless`.

  Config is merged from four sources, highest precedence first:

  1. Environment variables (`PLANCK_*`)
  2. Project-local JSON — `.planck/config.json` in the current working directory
  3. User-global JSON — `~/.planck/config.json`
  4. Application config — `config :planck_headless, ...`

  `load/0` is called at application start: it reads the JSON files and merges
  their keys into Application env *before* Skogsra resolves each key with
  env-var precedence. Env vars therefore always win.

  ## JSON file format

      {
        "default_provider": "anthropic",
        "default_model":    "claude-sonnet-4-6",
        "sessions_dir":     ".planck/sessions",
        "skills_dirs":      ["~/.planck/skills"],
        "tools_dirs":       ["~/.planck/tools"],
        "teams_dirs":       ["~/.planck/teams"],
        "compactor":        "~/.planck/compactor.exs"
      }

  All keys are optional. Unknown keys are ignored with a warning. Arrays are
  replaced rather than merged — a project-local `skills_dirs` wholly supersedes
  the global one. Users who want both paths should list both in the project file.

  ## Env vars

  | Env var                   | Config key           | Default                                              |
  |---------------------------|----------------------|------------------------------------------------------|
  | `PLANCK_DEFAULT_PROVIDER` | `:default_provider`  | `nil`                                                |
  | `PLANCK_DEFAULT_MODEL`    | `:default_model`     | `nil`                                                |
  | `PLANCK_SESSIONS_DIR`     | `:sessions_dir`      | `.planck/sessions`                                   |
  | `PLANCK_SKILLS_DIRS`      | `:skills_dirs`       | `.planck/skills:~/.planck/skills`                    |
  | `PLANCK_TOOLS_DIRS`       | `:tools_dirs`        | `.planck/tools:~/.planck/tools`                      |
  | `PLANCK_TEAMS_DIRS`       | `:teams_dirs`        | `.planck/teams:~/.planck/teams`                      |
  | `PLANCK_COMPACTOR`        | `:compactor`         | `nil`                                                |

  `*_DIRS` env vars take a colon-separated list; paths are expanded at runtime
  (`~` and relative paths resolved).
  """

  use Skogsra

  require Logger

  alias Planck.Headless.Config.PathList

  @typedoc """
  The resolved configuration struct returned by `get/0`.
  """
  @type t :: %__MODULE__{
          default_provider: atom() | nil,
          default_model: String.t() | nil,
          sessions_dir: Path.t(),
          skills_dirs: [Path.t()],
          tools_dirs: [Path.t()],
          teams_dirs: [Path.t()],
          compactor: Path.t() | nil
        }

  defstruct default_provider: nil,
            default_model: nil,
            sessions_dir: ".planck/sessions",
            skills_dirs: [".planck/skills", "~/.planck/skills"],
            tools_dirs: [".planck/tools", "~/.planck/tools"],
            teams_dirs: [".planck/teams", "~/.planck/teams"],
            compactor: nil

  @known_keys ~w(default_provider default_model sessions_dir skills_dirs tools_dirs teams_dirs compactor)
  @default_config_files ["~/.planck/config.json", ".planck/config.json"]

  # Caching is disabled so Application.put_env / reload_resources picks up
  # immediately. Config values are read a handful of times per session —
  # persistent-term caching is not worth the reload complexity.

  @envdoc "Default LLM provider (e.g. anthropic)."
  app_env :default_provider, :planck_headless, :default_provider,
    type: :atom,
    default: nil,
    cached: false

  @envdoc "Default model id within the default provider (e.g. claude-sonnet-4-6)."
  app_env :default_model, :planck_headless, :default_model, default: nil, cached: false

  @envdoc "Path to the sessions directory."
  app_env :sessions_dir, :planck_headless, :sessions_dir,
    default: ".planck/sessions",
    cached: false

  @envdoc "Colon-separated list of skill directories."
  app_env :skills_dirs, :planck_headless, :skills_dirs,
    type: PathList,
    default: [".planck/skills", "~/.planck/skills"],
    cached: false

  @envdoc "Colon-separated list of external-tool directories."
  app_env :tools_dirs, :planck_headless, :tools_dirs,
    type: PathList,
    default: [".planck/tools", "~/.planck/tools"],
    cached: false

  @envdoc "Colon-separated list of team directories."
  app_env :teams_dirs, :planck_headless, :teams_dirs,
    type: PathList,
    default: [".planck/teams", "~/.planck/teams"],
    cached: false

  @envdoc "Path to a `.exs` file defining a custom compactor module."
  app_env :compactor, :planck_headless, :compactor, default: nil, cached: false

  @doc """
  Read the JSON config files and merge their keys into the `:planck_headless`
  application environment.

  Called by `Planck.Headless.Application.start/2`. Safe to call more than once.

  Files are read in order — later files win. The default list is
  `~/.planck/config.json` (global) followed by `.planck/config.json`
  (project-local), so project-local values override global values. Missing
  files are silently skipped; malformed files log a warning and are skipped.

  The `:config_files` application env key overrides the default list, mostly
  for tests:

      config :planck_headless, :config_files, ["path/to/test-config.json"]
  """
  @spec load() :: :ok
  def load do
    files = Application.get_env(:planck_headless, :config_files, @default_config_files)
    Enum.each(files, &load_file/1)
    :ok
  end

  @doc """
  Return the fully-resolved config as a `%Planck.Headless.Config{}` struct.

  Each field is resolved via its Skogsra getter, so env vars win over the
  application env loaded by `load/0`, which wins over the struct defaults.
  """
  @spec get() :: t()
  def get do
    %__MODULE__{
      default_provider: default_provider!(),
      default_model: default_model!(),
      sessions_dir: sessions_dir!(),
      skills_dirs: skills_dirs!(),
      tools_dirs: tools_dirs!(),
      teams_dirs: teams_dirs!(),
      compactor: compactor!()
    }
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec load_file(Path.t()) :: :ok
  defp load_file(path) do
    expanded = Path.expand(path)

    case File.read(expanded) do
      {:ok, content} ->
        parse_and_merge(content, expanded)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Planck.Headless.Config] cannot read #{expanded}: #{:file.format_error(reason)}"
        )

        :ok
    end
  end

  @spec parse_and_merge(String.t(), Path.t()) :: :ok
  defp parse_and_merge(content, path) do
    case Jason.decode(content) do
      {:ok, map} when is_map(map) ->
        Enum.each(map, fn {key, value} -> merge_key(key, value, path) end)

      {:ok, other} ->
        Logger.warning(
          "[Planck.Headless.Config] #{path} must be a JSON object, got: #{inspect(other)}"
        )

      {:error, err} ->
        Logger.warning(
          "[Planck.Headless.Config] invalid JSON in #{path}: #{Exception.message(err)}"
        )
    end

    :ok
  end

  @spec merge_key(String.t(), term(), Path.t()) :: :ok
  defp merge_key(key, value, path) do
    if key in @known_keys do
      Application.put_env(:planck_headless, String.to_atom(key), value)
    else
      Logger.warning("[Planck.Headless.Config] unknown key #{inspect(key)} in #{path}, ignoring")
    end

    :ok
  end
end
