defmodule Planck.Headless.Config do
  @moduledoc """
  Resolved runtime configuration for `planck_headless`.

  Config is resolved by Skogsra, which reads from three sources in priority
  order (highest first):

  1. Environment variables (`PLANCK_*`)
  2. Application config — `config :planck, <key>, ...`
  3. Hardcoded defaults

  Values are cached in persistent terms via `preload/0` at application boot;
  the application also calls `validate!/0` to fail fast on malformed config.
  To change a value at runtime, set the application env and call the
  Skogsra-generated `reload_<key>/0` function.

  `planck_headless` does not read a user-editable config file. Persistent
  user configuration is either set via env vars or `config :planck, ...` in
  a consuming application's `config/runtime.exs`. If a CLI surface needs a
  JSON/YAML config file, it layers that on top before starting the
  application (e.g. `planck_cli`).

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

  defmodule PathList do
    @moduledoc false

    use Skogsra.Type

    @impl Skogsra.Type
    @spec cast(term()) :: {:ok, [String.t()]} | {:error, String.t()}
    def cast(value) when is_binary(value) do
      paths =
        value
        |> String.split(":")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      {:ok, paths}
    end

    def cast(value) when is_list(value) do
      if Enum.all?(value, &is_binary/1) do
        {:ok, value}
      else
        {:error, "expected a list of strings, got: #{inspect(value)}"}
      end
    end

    def cast(value) do
      {:error, "expected a colon-separated string or list of strings, got: #{inspect(value)}"}
    end
  end

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

  @envdoc "Default LLM provider (e.g. anthropic)."
  app_env :default_provider, :planck, :default_provider, type: :atom, default: nil

  @envdoc "Default model id within the default provider (e.g. claude-sonnet-4-6)."
  app_env :default_model, :planck, :default_model, default: nil

  @envdoc "Path to the sessions directory."
  app_env :sessions_dir, :planck, :sessions_dir, default: ".planck/sessions"

  @envdoc "Colon-separated list of skill directories."
  app_env :skills_dirs, :planck, :skills_dirs,
    type: PathList,
    default: [".planck/skills", "~/.planck/skills"]

  @envdoc "Colon-separated list of external-tool directories."
  app_env :tools_dirs, :planck, :tools_dirs,
    type: PathList,
    default: [".planck/tools", "~/.planck/tools"]

  @envdoc "Colon-separated list of team directories."
  app_env :teams_dirs, :planck, :teams_dirs,
    type: PathList,
    default: [".planck/teams", "~/.planck/teams"]

  @envdoc "Path to a `.exs` file defining a custom compactor module."
  app_env :compactor, :planck, :compactor, default: nil

  @doc """
  Return the fully-resolved config as a `%Planck.Headless.Config{}` struct.
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
end
