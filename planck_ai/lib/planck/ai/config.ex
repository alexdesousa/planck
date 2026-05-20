defmodule Planck.AI.Config do
  @moduledoc """
  Converts model configuration into `Planck.AI.Model` structs.

  The entry point is `from_config/2`, which accepts the v0.1.6 config format:
  a `providers` map (user-keyed) and a `models` list where each entry references
  a provider by key.

  ## Format

      providers = %{
        "anthropic" => %{"type" => "anthropic"},
        "nvidia"    => %{"type" => "openai", "base_url" => "https://integrate.api.nvidia.com/v1", "identifier" => "NVIDIA"},
        "local"     => %{"type" => "openai", "base_url" => "http://localhost:11434", "has_api_key" => false}
      }

      models = [
        %{"id" => "sonnet",   "model" => "claude-sonnet-4-6",             "provider" => "anthropic"},
        %{"id" => "llama70b", "model" => "meta/llama-3.3-70b-instruct",   "provider" => "nvidia"},
        %{"id" => "llama3.2", "model" => "llama3.2",                      "provider" => "local"}
      ]

      models = Planck.AI.Config.from_config(providers, models)

  """

  require Logger

  alias Planck.AI.Model

  @valid_providers Planck.AI.list_providers() |> Enum.map(&to_string/1)

  @doc """
  Builds a list of `Model` structs from the v0.1.6 config format, which separates
  provider entries (keyed map) from model entries (list).

  Each model entry must reference a key in `providers` via its `"provider"` field.
  Invalid entries are skipped with a warning; the rest are returned.
  """
  @spec from_config(%{String.t() => map()}, [map()]) :: [Model.t()]
  def from_config(providers, models)

  def from_config(providers, models) when is_map(providers) and is_list(models) do
    Enum.flat_map(models, fn entry ->
      case from_config_entry(providers, entry) do
        {:ok, model} ->
          [model]

        {:error, reason} ->
          Logger.warning("[Planck.AI.Config] skipping model: #{reason} — #{inspect(entry)}")
          []
      end
    end)
  end

  @spec from_config_entry(%{String.t() => map()}, map()) ::
          {:ok, Model.t()} | {:error, String.t()}
  defp from_config_entry(providers, entry)

  defp from_config_entry(
         providers,
         %{"id" => id, "model" => model_id, "provider" => provider_key} = entry
       )
       when is_binary(id) and id != "" and is_binary(model_id) and is_binary(provider_key) do
    case Map.fetch(providers, provider_key) do
      {:ok, prov_entry} ->
        build_from_config_entry(id, model_id, prov_entry, entry)

      :error ->
        {:error, "unknown provider key #{inspect(provider_key)}"}
    end
  end

  defp from_config_entry(_, %{"id" => ""}) do
    {:error, "id must not be empty"}
  end

  defp from_config_entry(_, %{"id" => _, "model" => _, "provider" => _}) do
    {:error, "id, model, and provider must be strings"}
  end

  defp from_config_entry(_, %{"id" => _}) do
    {:error, "missing required fields: model, provider"}
  end

  defp from_config_entry(_, _) do
    {:error, "missing required field: id"}
  end

  @spec build_from_config_entry(String.t(), String.t(), map(), map()) ::
          {:ok, Model.t()} | {:error, String.t()}
  defp build_from_config_entry(id, model_id, prov_entry, entry)

  defp build_from_config_entry(id, model_id, prov_entry, entry) do
    with {:ok, provider} <- parse_provider(prov_entry["type"] || ""),
         {:ok, identifier} <- parse_identifier(provider, prov_entry["identifier"]) do
      has_api_key = Map.get(prov_entry, "has_api_key", true)

      {:ok,
       %Model{
         id: id,
         model: model_id,
         name: entry["name"] || id,
         provider: provider,
         base_url: prov_entry["base_url"],
         identifier: identifier,
         has_api_key: has_api_key,
         context_window: entry["context_window"] || 4_096,
         max_tokens: entry["max_tokens"] || 2_048,
         supports_thinking: entry["supports_thinking"] || false,
         input_types: parse_input_types(entry["input_types"]),
         default_opts: parse_default_opts(entry["params"] || entry["default_opts"])
       }}
    end
  end

  @spec parse_identifier(atom(), term()) ::
          {:ok, String.t() | nil}
          | {:error, String.t()}
  defp parse_identifier(provider, raw)

  defp parse_identifier(:openai, nil) do
    {:ok, nil}
  end

  defp parse_identifier(:openai, raw) when is_binary(raw) do
    upcased = String.upcase(raw)

    if Regex.match?(~r/^[A-Z][A-Z0-9]*$/, upcased) do
      {:ok, upcased}
    else
      {:error, "identifier must match [A-Z][A-Z0-9]*: #{inspect(raw)}"}
    end
  end

  defp parse_identifier(:openai, other) do
    {:error, "identifier must be a string, got: #{inspect(other)}"}
  end

  defp parse_identifier(_provider, raw) do
    {:ok, raw}
  end

  @spec parse_provider(String.t()) :: {:ok, atom()} | {:error, String.t()}
  defp parse_provider(provider)

  defp parse_provider(provider) when provider in @valid_providers do
    {:ok, String.to_atom(provider)}
  end

  defp parse_provider(provider) do
    {:error,
     "unknown provider type #{inspect(provider)}; valid: #{Enum.join(@valid_providers, ", ")}"}
  end

  @spec parse_input_types(term()) :: [atom()]
  defp parse_input_types(inputs)

  defp parse_input_types(list) when is_list(list) do
    types = Enum.flat_map(list, &parse_input_type/1)
    if types == [], do: [:text], else: types
  end

  defp parse_input_types(_) do
    [:text]
  end

  @spec parse_input_type(String.t()) :: [atom()]
  defp parse_input_type(input_type)

  defp parse_input_type("text"), do: [:text]
  defp parse_input_type("image"), do: [:image]
  defp parse_input_type("image_url"), do: [:image_url]
  defp parse_input_type("file"), do: [:file]
  defp parse_input_type("video_url"), do: [:video_url]
  defp parse_input_type(_), do: []

  @spec parse_default_opts(map() | nil | term()) :: keyword()
  defp parse_default_opts(options)

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

  defp parse_default_opts(_) do
    []
  end
end
