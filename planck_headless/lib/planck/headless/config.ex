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
  read via `JsonBinding` as part of Skogsra's binding chain. Keys that appear
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
  functions directly (e.g. `Config.anthropic_api_key!/0`).

  | Env var               | Config key             | Used for                   |
  |-----------------------|------------------------|----------------------------|
  | `ANTHROPIC_API_KEY`   | `:anthropic_api_key`   | Anthropic (Claude) models  |
  | `OPENAI_API_KEY`      | `:openai_api_key`      | OpenAI models              |
  | `GOOGLE_API_KEY`      | `:google_api_key`      | Google (Gemini) models     |
  """

  use Skogsra

  defmodule Models do
    @moduledoc false

    # Skogsra type for the `models` config key. Accepts a list of model-entry
    # maps and parses them via `Planck.AI.Config.from_list/1`, producing a list
    # of `%Planck.AI.Model{}` structs. Invalid entries are skipped with a
    # warning (delegated to `Planck.AI.Config`). No env-var form — model
    # declarations are too structured for a flat string.

    use Skogsra.Type

    @impl Skogsra.Type
    @spec cast(term()) :: {:ok, [Planck.AI.Model.t()]} | {:error, String.t()}
    def cast(list) when is_list(list), do: {:ok, Planck.AI.Config.from_list(list)}
    def cast(_), do: {:error, "expected a list of model maps"}
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
          teams_dirs: [Path.t()],
          sidecar: Path.t(),
          models: [Planck.AI.Model.t()]
        }

  defstruct default_provider: nil,
            default_model: nil,
            sessions_dir: ".planck/sessions",
            skills_dirs: [".planck/skills", "~/.planck/skills"],
            teams_dirs: [".planck/teams", "~/.planck/teams"],
            sidecar: ".planck/sidecar",
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
  List of model declarations for local providers (and optional cloud model
  overrides). Each entry follows the `Planck.AI.Config` JSON format. Only
  readable from `.planck/config.json` or application config — no env var
  equivalent (the format is too structured for a flat string).

  Example (in .planck/config.json):
  ```json
  "models": [
    {
      "id":             "llama3.2",
      "provider":       "ollama",
      "base_url":       "http://localhost:11434",
      "context_window": 128000,
      "default_opts":   {"temperature": 0.7, "top_p": 0.9}
    },
    {
      "id":             "mistral",
      "provider":       "llama_cpp",
      "base_url":       "http://localhost:8080",
      "context_window": 32768,
      "default_opts":   {"temperature": 0.5}
    }
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
      teams_dirs: teams_dirs!(),
      sidecar: sidecar!(),
      models: models!()
    }
  end
end
