defmodule Planck.AI.Config do
  @moduledoc """
  Converts model configuration into `Planck.AI.Model` structs.

  Two entry points are provided:

  - `load/1` — reads and parses a JSON file directly.
  - `from_list/1` — accepts an already-decoded list of maps, for callers (e.g.
    a CLI tool) that parse a larger config file themselves and extract only the
    models section before passing it here.

  Each entry in the list maps to one `%Planck.AI.Model{}`. Only `"id"` and
  `"provider"` are required; all other fields have sensible defaults.

  ## JSON format

      [
        {
          "id": "my-local-llama",
          "provider": "llama_cpp",
          "name": "Local Llama 3.2",
          "base_url": "http://localhost:8080",
          "context_window": 32768,
          "max_tokens": 4096,
          "supports_thinking": false,
          "input_types": ["text"],
          "default_opts": {
            "temperature": 0.8,
            "top_p": 0.95,
            "top_k": 40
          }
        },
        {
          "id": "qwen3-coder:7b",
          "provider": "ollama",
          "context_window": 40960
        }
      ]

  ## Loading from a file

      {:ok, models} = Planck.AI.Config.load("config/models.json")

  ## Loading from a pre-decoded list

      # e.g. the CLI decoded a larger config and extracted the models section
      models = Planck.AI.Config.from_list(decoded_config["models"])

  """

  require Logger

  alias Planck.AI.Model

  @valid_providers ~w(anthropic openai google ollama llama_cpp)

  @doc """
  Loads models from a JSON file at `path`.

  Returns `{:ok, [Model.t()]}` on success. Invalid entries are skipped with a
  warning logged at the `:warning` level. Returns `{:error, reason}` if the
  file cannot be read or if the JSON is malformed.
  """
  @spec load(Path.t()) :: {:ok, [Model.t()]} | {:error, term()}
  def load(path) do
    with {:ok, content} <- File.read(path),
         {:ok, data} <- Jason.decode(content) do
      {:ok, from_list(data)}
    end
  end

  @doc """
  Converts a list of maps (as decoded from JSON) into a list of `Model` structs.

  Invalid entries are skipped with a warning; the rest are returned.
  """
  @spec from_list([map()]) :: [Model.t()]
  def from_list(entries) when is_list(entries) do
    Enum.flat_map(entries, fn entry ->
      case from_map(entry) do
        {:ok, model} ->
          [model]

        {:error, reason} ->
          Logger.warning("[Planck.AI.Config] skipping entry: #{reason} — #{inspect(entry)}")
          []
      end
    end)
  end

  @doc """
  Converts a single map into a `Model` struct.

  Returns `{:ok, model}` or `{:error, reason}`.
  """
  @spec from_map(map()) :: {:ok, Model.t()} | {:error, String.t()}
  def from_map(%{"id" => id, "provider" => raw_provider} = entry)
      when is_binary(id) and id != "" do
    with {:ok, provider} <- parse_provider(raw_provider) do
      {:ok,
       %Model{
         id: id,
         name: entry["name"] || id,
         provider: provider,
         base_url: entry["base_url"],
         context_window: entry["context_window"] || 4_096,
         max_tokens: entry["max_tokens"] || 2_048,
         supports_thinking: entry["supports_thinking"] || false,
         input_types: parse_input_types(entry["input_types"]),
         default_opts: parse_default_opts(entry["default_opts"])
       }}
    end
  end

  def from_map(%{"id" => ""}), do: {:error, "id must not be empty"}
  def from_map(%{"id" => _}), do: {:error, "missing required field: provider"}
  def from_map(_), do: {:error, "missing required field: id"}

  defp parse_provider(p) when p in @valid_providers, do: {:ok, String.to_existing_atom(p)}

  defp parse_provider(p) do
    {:error, "unknown provider #{inspect(p)}; valid: #{Enum.join(@valid_providers, ", ")}"}
  end

  defp parse_input_types(nil), do: [:text]

  defp parse_input_types(list) when is_list(list) do
    types =
      list
      |> Enum.flat_map(&parse_input_type/1)

    if types == [], do: [:text], else: types
  end

  defp parse_input_types(_), do: [:text]

  defp parse_input_type("text"), do: [:text]
  defp parse_input_type("image"), do: [:image]
  defp parse_input_type("image_url"), do: [:image_url]
  defp parse_input_type("file"), do: [:file]
  defp parse_input_type("video_url"), do: [:video_url]
  defp parse_input_type(_), do: []

  defp parse_default_opts(nil), do: []

  defp parse_default_opts(map) when is_map(map) do
    Enum.flat_map(map, fn {k, v} ->
      try do
        [{String.to_existing_atom(k), v}]
      rescue
        ArgumentError ->
          Logger.warning("[Planck.AI.Config] unknown default_opt key #{inspect(k)}, skipping")
          []
      end
    end)
  end

  defp parse_default_opts(_), do: []
end
