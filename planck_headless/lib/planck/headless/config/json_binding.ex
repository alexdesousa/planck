defmodule Planck.Headless.Config.JsonBinding do
  @moduledoc false

  # Skogsra binding that reads ~/.planck/config.json and .planck/config.json.
  # Later files win (project-local overrides user-global).
  # The merged map is cached in persistent_term after the first resolution.
  #
  # Set `config :planck_headless, :skip_json_config, true` in test envs to
  # skip this binding entirely: `init/1` returns `:error` so Skogsra bypasses
  # the binding without emitting `:not_found` warnings for every key.
  #
  # Call invalidate/0 before ResourceStore.reload/0 to pick up file changes.

  use Skogsra.Binding

  alias Planck.Headless.Config

  require Logger

  @cache_key {__MODULE__, :config}

  @impl true
  def init(_env) do
    if Application.get_env(:planck_headless, :skip_json_config, false),
      do: :error,
      else: {:ok, cached_config()}
  end

  @impl true
  def get_env(env, config) do
    key = env.keys |> List.last() |> to_string()

    case Map.fetch(config, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :not_found}
    end
  end

  @doc "Clear the JSON config cache so the next resolution reloads from disk."
  @spec invalidate() :: :ok
  def invalidate do
    :persistent_term.erase(@cache_key)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec cached_config() :: map()
  defp cached_config do
    case :persistent_term.get(@cache_key, :miss) do
      :miss ->
        config = load_files()
        :persistent_term.put(@cache_key, config)
        config

      config ->
        config
    end
  end

  @spec load_files() :: map()
  defp load_files do
    Enum.reduce(Config.config_files!(), %{}, fn path, acc ->
      case load_file(path) do
        {:ok, map} -> Map.merge(acc, map)
        :skip -> acc
      end
    end)
  end

  @spec load_file(Path.t()) :: {:ok, map()} | :skip
  defp load_file(path) do
    with {:ok, content} <- read_file(Path.expand(path)) do
      decode_json(content, path)
    end
  end

  @spec read_file(Path.t()) :: {:ok, String.t()} | :skip
  defp read_file(path) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, content}

      {:error, :enoent} ->
        :skip

      {:error, reason} ->
        Logger.warning(
          "[Planck.Headless.Config] cannot read #{path}: #{:file.format_error(reason)}"
        )

        :skip
    end
  end

  @spec decode_json(String.t(), Path.t()) :: {:ok, map()} | :skip
  defp decode_json(content, path) do
    case Jason.decode(content) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      {:ok, _other} ->
        Logger.warning("[Planck.Headless.Config] #{path} must be a JSON object, skipping")
        :skip

      {:error, err} ->
        Logger.warning(
          "[Planck.Headless.Config] invalid JSON in #{path}: #{Exception.message(err)}"
        )

        :skip
    end
  end
end
