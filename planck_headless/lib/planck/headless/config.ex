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

  ### Planner config

  | Env var                   | Config key           | Default                           |
  |---------------------------|----------------------|-----------------------------------|
  | `PLANCK_DEFAULT_PROVIDER` | `:default_provider`  | `nil`                             |
  | `PLANCK_DEFAULT_MODEL`    | `:default_model`     | `nil`                             |
  | `PLANCK_SESSIONS_DIR`     | `:sessions_dir`      | `.planck/sessions`                |
  | `PLANCK_SKILLS_DIRS`      | `:skills_dirs`       | `.planck/skills:~/.planck/skills` |
  | `PLANCK_TOOLS_DIRS`       | `:tools_dirs`        | `.planck/tools:~/.planck/tools`   |
  | `PLANCK_TEAMS_DIRS`       | `:teams_dirs`        | `.planck/teams:~/.planck/teams`   |
  | `PLANCK_COMPACTOR`        | `:compactor`         | `nil`                             |

  `*_DIRS` env vars take a colon-separated list; paths are expanded at runtime
  (`~` and relative paths resolved).

  ### Provider API keys

  API keys are not included in `get/0` or the `%Config{}` struct to avoid
  accidental exposure in logs or inspect output. Use the generated getter
  functions directly (e.g. `Config.anthropic_api_key!/0`).

  | Env var               | Config key             | Used for                   |
  |-----------------------|------------------------|----------------------------|
  | `ANTHROPIC_API_KEY`   | `:anthropic_api_key`   | Anthropic (Claude) models  |
  | `OPENAI_API_KEY`      | `:openai_api_key`      | OpenAI models              |
  | `GOOGLE_API_KEY`      | `:google_api_key`      | Google (Gemini) models     |
  """

  use Skogsra

  defmodule LocalServers do
    @moduledoc false

    use Skogsra.Type

    @impl Skogsra.Type
    @spec cast(term()) :: {:ok, [%{type: atom(), base_url: String.t()}]} | {:error, String.t()}
    def cast(value) when is_binary(value) do
      servers =
        value
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(fn entry ->
          case String.split(entry, ":", parts: 2) do
            [type, base_url] -> %{type: String.to_atom(type), base_url: base_url}
            _ -> {:error, entry}
          end
        end)

      if Enum.all?(servers, &is_map/1) do
        {:ok, servers}
      else
        {:error, "invalid PLANCK_LOCAL_SERVERS format; expected \"type:url,...\""}
      end
    end

    def cast(value) when is_list(value) do
      servers =
        Enum.map(value, fn
          %{"type" => type, "base_url" => base_url} ->
            %{type: String.to_atom(type), base_url: base_url}

          %{type: type, base_url: base_url} ->
            %{type: type, base_url: base_url}
        end)

      {:ok, servers}
    end

    def cast(value) do
      {:error, "expected a comma-separated string or list of server maps, got: #{inspect(value)}"}
    end
  end

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
          compactor: Path.t() | nil,
          local_servers: [%{type: atom(), base_url: String.t()}]
        }

  defstruct default_provider: nil,
            default_model: nil,
            sessions_dir: ".planck/sessions",
            skills_dirs: [".planck/skills", "~/.planck/skills"],
            tools_dirs: [".planck/tools", "~/.planck/tools"],
            teams_dirs: [".planck/teams", "~/.planck/teams"],
            compactor: nil,
            local_servers: []

  @envdoc """
  Colon-separated list of JSON config files to read at boot, in order.
  Later files override earlier ones. Not read from the JSON files themselves —
  that would be circular. Defaults to the user-global file followed by the
  project-local file (project-local wins on collision).
  """
  app_env :config_files, :planck, :config_files,
    type: PathList,
    default: ["~/.planck/config.json", ".planck/config.json"]

  # Config keys that can also be set in .planck/config.json or ~/.planck/config.json.
  # API keys are intentionally excluded — credentials must not live in config files.
  @json [:system, Planck.Headless.Config.JsonBinding, :config]

  @envdoc "Default LLM provider (e.g. anthropic)."
  app_env :default_provider, :planck, :default_provider,
    type: :atom,
    default: nil,
    binding_order: @json

  @envdoc "Default model id within the default provider (e.g. claude-sonnet-4-6)."
  app_env :default_model, :planck, :default_model,
    default: nil,
    binding_order: @json

  @envdoc "Path to the sessions directory."
  app_env :sessions_dir, :planck, :sessions_dir,
    default: ".planck/sessions",
    binding_order: @json

  @envdoc "Colon-separated list of skill directories."
  app_env :skills_dirs, :planck, :skills_dirs,
    type: PathList,
    default: [".planck/skills", "~/.planck/skills"],
    binding_order: @json

  @envdoc "Colon-separated list of external-tool directories."
  app_env :tools_dirs, :planck, :tools_dirs,
    type: PathList,
    default: [".planck/tools", "~/.planck/tools"],
    binding_order: @json

  @envdoc "Colon-separated list of team directories."
  app_env :teams_dirs, :planck, :teams_dirs,
    type: PathList,
    default: [".planck/teams", "~/.planck/teams"],
    binding_order: @json

  @envdoc "Path to a `.exs` file defining a custom compactor module."
  app_env :compactor, :planck, :compactor,
    default: nil,
    binding_order: @json

  @envdoc """
  Comma-separated list of local model servers in `type:base_url` format.
  Multiple servers of the same type are supported.

  Example: `ollama:http://localhost:11434,llama_cpp:http://localhost:8080`
  """
  app_env :local_servers, :planck, :local_servers,
    type: LocalServers,
    default: [],
    binding_order: @json

  # Provider API keys — not included in get/0 or %Config{} to avoid
  # accidental exposure. Use the generated getters directly.

  @envdoc "Anthropic API key."
  app_env :anthropic_api_key, :planck, :anthropic_api_key,
    os_env: "ANTHROPIC_API_KEY",
    default: nil

  @envdoc "OpenAI API key."
  app_env :openai_api_key, :planck, :openai_api_key,
    os_env: "OPENAI_API_KEY",
    default: nil

  @envdoc "Google API key."
  app_env :google_api_key, :planck, :google_api_key,
    os_env: "GOOGLE_API_KEY",
    default: nil

  @doc "Return the fully-resolved config as a `%Planck.Headless.Config{}` struct."
  @spec get() :: t()
  def get do
    %__MODULE__{
      default_provider: default_provider!(),
      default_model: default_model!(),
      sessions_dir: sessions_dir!(),
      skills_dirs: skills_dirs!(),
      tools_dirs: tools_dirs!(),
      teams_dirs: teams_dirs!(),
      compactor: compactor!(),
      local_servers: local_servers!()
    }
  end
end
