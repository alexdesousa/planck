defmodule Planck.Agent.Config do
  @moduledoc """
  Application configuration for `planck_agent`.

  Variables can be set via the OS environment or application config.

  | Key | OS env var | Default |
  |---|---|---|
  | `:sessions_dir` | `PLANCK_AGENT_SESSIONS_DIR` | `.planck/sessions` |
  | `:skills_dirs` | `PLANCK_AGENT_SKILLS_DIRS` | `.planck/skills:~/.planck/skills` |

  `PLANCK_AGENT_SKILLS_DIRS` accepts a colon-separated list of paths.
  Paths are expanded at runtime — relative paths anchor to the current working
  directory, `~` expands to the user home directory.
  """

  use Skogsra

  @envdoc "Path to the sessions directory."
  app_env :sessions_dir, :planck_agent, :sessions_dir, default: ".planck/sessions"

  @envdoc """
  Colon-separated list of directories to search for skills.
  Paths are expanded at runtime (`~` and relative paths resolved).
  """
  app_env :skills_dirs, :planck_agent, :skills_dirs,
    type: Planck.Agent.Config.PathList,
    default: [".planck/skills", "~/.planck/skills"]

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
end
