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

  JSON config files (`~/.planck/config.json` and `.planck/config.json`) are
  read via `JsonBinding` (internal module) as part of Skogsra's binding chain. Keys that appear
  in a JSON file override application config but are overridden by env vars.

  ## Env vars

  ### Planner config

  | Env var                   | Config key           | Default                           |
  |---------------------------|----------------------|-----------------------------------|
  | `PLANCK_DEFAULT_PROVIDER` | `:default_provider`  | `nil`                             |
  | `PLANCK_DEFAULT_MODEL`    | `:default_model`     | `nil`                             |
  | `PLANCK_SESSIONS_DIR`     | `:sessions_dir`      | `.planck/sessions`                |
  | `PLANCK_SKILLS_DIRS`      | `:skills_dirs`       | `.planck/skills:~/.planck/skills` |
  | `PLANCK_TEAMS_DIRS`       | `:teams_dirs`        | `.planck/teams:~/.planck/teams`   |
  | `PLANCK_SIDECAR`          | `:sidecar`           | `.planck/sidecar`                 |

  `*_DIRS` env vars take a colon-separated list; paths are expanded at runtime
  (`~` and relative paths resolved). The `:models` key has no env var
  equivalent — declare models in `.planck/config.json` or
  `config :planck, :models, [...]`.

  ### Provider API keys

  API keys are not included in `get/0` or the `%Config{}` struct to avoid
  accidental exposure in logs or inspect output. Use the generated getter
  functions directly (e.g. `Planck.Headless.Config.anthropic_api_key!/0`).

  | Env var               | Config key             | Used for                   |
  |-----------------------|------------------------|----------------------------|
  | `ANTHROPIC_API_KEY`   | `:anthropic_api_key`   | Anthropic (Claude) models  |
  | `OPENAI_API_KEY`      | `:openai_api_key`      | OpenAI models              |
  | `GOOGLE_API_KEY`      | `:google_api_key`      | Google (Gemini) models     |
  """

  use Skogsra

  defmodule Providers do
    @moduledoc "Skogsra type for the providers map in config.json."

    use Skogsra.Type

    @impl Skogsra.Type
    @spec cast(term()) :: {:ok, %{String.t() => map()}} | {:error, String.t()}
    def cast(map) when is_map(map), do: {:ok, map}
    def cast(_), do: {:error, "expected a map of provider entries"}
  end

  defmodule Models do
    @moduledoc "Skogsra type for the models list in config.json."

    # Raw list passthrough — model structs are built lazily by
    # Planck.AI.Config.from_config/2 when available_models are needed.
    # No env-var form — model declarations are too structured for a flat string.

    use Skogsra.Type

    @impl Skogsra.Type
    @spec cast(term()) :: {:ok, [map()]} | {:error, String.t()}
    def cast(list) when is_list(list), do: {:ok, list}
    def cast(_), do: {:error, "expected a list of model entries"}
  end

  defmodule PathList do
    @moduledoc """
    Skogsra type for path lists set via environment variables.

    Uses `:` as separator on Unix and `;` on Windows, matching each platform's
    `PATH` convention. Both separators are accepted on all platforms so that
    cross-platform config files stay portable. Drive-letter colons (e.g. `C:`)
    are never mistaken for separators because they are immediately followed by
    `\\` or `/`.

    Examples:
      Unix:    `~/.planck/skills:.planck/skills`
      Windows: `~/.planck/skills;.planck/skills`
    """

    use Skogsra.Type

    @impl Skogsra.Type
    @spec cast(term()) :: {:ok, [String.t()]} | {:error, String.t()}
    def cast(value) when is_binary(value) do
      paths =
        value
        |> String.split(~r/;|:(?![\/\\])/)
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
      {:error, "expected a path list string or list of strings, got: #{inspect(value)}"}
    end
  end

  @typedoc """
  The resolved configuration struct returned by `get/0`.
  """
  @type t :: %__MODULE__{
          default_provider: String.t() | nil,
          default_model: String.t() | nil,
          sessions_dir: Path.t(),
          skills_dirs: [Path.t()],
          teams_dirs: [Path.t()],
          sidecar: Path.t(),
          providers: %{String.t() => map()},
          models: [map()]
        }

  defstruct default_provider: nil,
            default_model: nil,
            sessions_dir: ".planck/sessions",
            skills_dirs: [".planck/skills", "~/.planck/skills"],
            teams_dirs: [".planck/teams", "~/.planck/teams"],
            sidecar: ".planck/sidecar",
            providers: %{},
            models: []

  @envdoc """
  Colon-separated list of JSON config files to read at boot, in order.
  Later files override earlier ones. Not read from the JSON files themselves —
  that would be circular. Defaults to the user-global file followed by the
  project-local file (project-local wins on collision).
  """
  app_env :config_files, :planck, :config_files,
    type: PathList,
    default: ["~/.planck/config.json", ".planck/config.json"]

  @envdoc """
  Ordered list of `.env` files to read for API keys.
  Global file is read first; project-local file wins on collision.
  Not read from the `.env` files themselves — that would be circular.
  """
  app_env :env_files, :planck, :env_files,
    type: PathList,
    default: ["~/.planck/.env", "./.planck/.env"]

  # Config keys that can also be set in .planck/config.json or ~/.planck/config.json.
  # API keys are intentionally excluded — credentials must not live in config files.
  @json [:system, Planck.Headless.Config.JsonBinding, :config]

  # API key binding order: system env → project .env → global .env → Elixir config.
  @dotenv [:system, Planck.Headless.Config.EnvBinding, :config]

  @envdoc "Default provider key — references an entry in the `providers` map (e.g. \"anthropic\")."
  app_env :default_provider, :planck, :default_provider,
    default: nil,
    binding_order: @json

  @envdoc "Default model id within the default provider (e.g. claude-sonnet-4-6)."
  app_env :default_model, :planck, :default_model,
    default: nil,
    binding_order: @json

  @envdoc """
  UI locale (e.g. `"en"`, `"es"`). Set in `.planck/config.json` for a
  project-specific language or in `~/.planck/config.json` for a global
  preference. When absent the browser's Accept-Language header is used,
  falling back to English.
  """
  app_env :locale, :planck, :locale,
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

  @envdoc "Colon-separated list of team directories."
  app_env :teams_dirs, :planck, :teams_dirs,
    type: PathList,
    default: [".planck/teams", "~/.planck/teams"],
    binding_order: @json

  @envdoc """
  Path to the sidecar Mix project directory. planck_headless starts the sidecar
  application from this path when it exists on disk. Set to a non-existent path
  to disable sidecar startup.
  """
  app_env :sidecar, :planck, :sidecar,
    os_env: "PLANCK_SIDECAR",
    default: ".planck/sidecar",
    binding_order: @json

  @envdoc """
  Map of named provider entries. Each key is a user-defined provider alias;
  the value describes the provider type and connection details. Only readable
  from `.planck/config.json` or application config — no env var equivalent.

  Example (in .planck/config.json):
  ```json
  "providers": {
    "anthropic":    { "type": "anthropic" },
    "nvidia":       { "type": "openai", "base_url": "https://integrate.api.nvidia.com/v1", "identifier": "NVIDIA" },
    "local-ollama": { "type": "openai", "base_url": "http://localhost:11434", "has_api_key": false }
  }
  ```
  """
  app_env :providers, :planck, :providers,
    type: Providers,
    default: %{},
    binding_order: @json

  @envdoc """
  List of model declarations. Each entry references a key in `providers` and
  assigns a user alias. Only readable from `.planck/config.json` or application
  config — no env var equivalent (the format is too structured for a flat string).

  Example (in .planck/config.json):
  ```json
  "models": [
    { "id": "sonnet",   "model": "claude-sonnet-4-6",              "provider": "anthropic" },
    { "id": "llama70b", "model": "meta/llama-3.3-70b-instruct",    "provider": "nvidia",
      "params": { "temperature": 0.6, "receive_timeout": 600000 } }
  ]
  ```
  """
  app_env :models, :planck, :models,
    type: Models,
    default: [],
    binding_order: @json

  # Provider API keys — not included in get/0 or %Config{} to avoid
  # accidental exposure. Use the generated getters directly.

  @envdoc "Anthropic API key."
  app_env :anthropic_api_key, :req_llm, :anthropic_api_key,
    os_env: "ANTHROPIC_API_KEY",
    default: nil,
    binding_order: @dotenv

  @envdoc "OpenAI API key."
  app_env :openai_api_key, :req_llm, :openai_api_key,
    os_env: "OPENAI_API_KEY",
    default: nil,
    binding_order: @dotenv

  @envdoc "Google API key."
  app_env :google_api_key, :req_llm, :google_api_key,
    os_env: "GOOGLE_API_KEY",
    default: nil,
    binding_order: @dotenv

  @doc "Return the fully-resolved config as a `%Planck.Headless.Config{}` struct."
  @spec get() :: t()
  def get do
    %__MODULE__{
      default_provider: default_provider!(),
      default_model: default_model!(),
      sessions_dir: sessions_dir!(),
      skills_dirs: skills_dirs!(),
      teams_dirs: teams_dirs!(),
      sidecar: sidecar!(),
      providers: providers!(),
      models: models!()
    }
  end
end
