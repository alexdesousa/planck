defmodule Planck.Headless.Config.EnvBinding do
  @moduledoc false

  # Skogsra binding that reads ~/.planck/.env and ./.planck/.env.
  # The project-local file takes precedence over the user-global file.
  # The merged map is cached in persistent_term after the first resolution.
  #
  # Set `config :planck_headless, :skip_env_config, true` in test envs to
  # skip this binding entirely.
  #
  # Call invalidate/0 to bust the cache when files change on disk.

  use Skogsra.Binding

  alias Planck.Headless.Config

  require Logger

  @cache_key {__MODULE__, :env}

  @impl true
  def init(_env) do
    if Application.get_env(:planck_headless, :skip_env_config, false),
      do: :error,
      else: {:ok, cached_env()}
  end

  @impl true
  def get_env(env, dotenv_map) do
    key =
      Keyword.get(env.options, :os_env) ||
        env.keys |> List.last() |> to_string() |> String.upcase()

    case Map.fetch(dotenv_map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :not_found}
    end
  end

  @doc "Clear the .env cache so the next resolution reloads from disk."
  @spec invalidate() :: :ok
  def invalidate do
    :persistent_term.erase(@cache_key)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec cached_env() :: map()
  defp cached_env do
    case :persistent_term.get(@cache_key, :miss) do
      :miss ->
        env = load_files()
        :persistent_term.put(@cache_key, env)
        env

      env ->
        env
    end
  end

  @spec load_files() :: map()
  defp load_files do
    Config.env_files!()
    |> Enum.reduce(%{}, fn path, acc ->
      case load_file(path) do
        {:ok, map} -> Map.merge(acc, map)
        :skip -> acc
      end
    end)
  end

  @spec load_file(Path.t()) :: {:ok, map()} | :skip
  defp load_file(path)

  defp load_file(path) when is_binary(path) do
    path
    |> Path.expand()
    |> File.read()
    |> case do
      {:ok, content} ->
        {:ok, parse(content)}

      {:error, :enoent} ->
        :skip

      {:error, reason} ->
        Logger.warning(
          "[Planck.Headless.Config] cannot read #{path}: #{:file.format_error(reason)}"
        )

        :skip
    end
  end

  @spec parse(String.t()) :: map()
  defp parse(content)

  defp parse(content) when is_binary(content) do
    content
    |> String.split("\n")
    |> Stream.flat_map(&parse_line/1)
    |> Map.new()
  end

  @spec parse_line(String.t()) :: [{String.t(), String.t()}]
  defp parse_line(line)

  defp parse_line(line) when is_binary(line) do
    line = String.trim(line)

    with false <- line == "" or String.starts_with?(line, "#"),
         [key, value] <- String.split(line, "=", parts: 2) do
      key = String.trim(key)

      value =
        value
        |> String.trim()
        |> strip_quotes()

      [{key, value}]
    else
      _ -> []
    end
  end

  @spec strip_quotes(String.t()) :: String.t()
  defp strip_quotes(value)
  defp strip_quotes(<<"\"", rest::binary>>), do: String.trim_trailing(rest, "\"")
  defp strip_quotes(<<"'", rest::binary>>), do: String.trim_trailing(rest, "'")
  defp strip_quotes(value), do: value
end
