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
    case sanitize_identifier(raw) do
      {:ok, cleaned} -> {:ok, cleaned}
      :error -> {:error, "identifier must contain at least one letter: #{inspect(raw)}"}
    end
  end

  defp parse_identifier(:openai, other) do
    {:error, "identifier must be a string, got: #{inspect(other)}"}
  end

  defp parse_identifier(_provider, raw) do
    {:ok, raw}
  end

  @doc """
  Normalizes a user-supplied identifier into a valid env-var tag: upcased,
  characters outside `A-Z0-9` replaced with `_`, and leading non-letter
  characters stripped (env var names must start with a letter).

  Used both when loading config (so a typo'd identifier degrades to a
  usable tag instead of dropping the model) and when writing config via
  `Planck.Headless.configure_provider/1` (so the persisted identifier and
  the `.env` key it derives always agree).

  Returns `:error` only when nothing but non-letters remains (e.g. `"3.6"`).

      iex> Planck.AI.Config.sanitize_identifier("Qwen 3.6 27B")
      {:ok, "QWEN_3_6_27B"}

      iex> Planck.AI.Config.sanitize_identifier("nvidia")
      {:ok, "NVIDIA"}
  """
  @spec sanitize_identifier(String.t()) :: {:ok, String.t()} | :error
  def sanitize_identifier(raw) do
    cleaned =
      raw
      |> String.upcase()
      |> String.replace(~r/[^A-Z0-9]/, "_")
      |> String.replace(~r/^[^A-Z]+/, "")

    if cleaned == "", do: :error, else: {:ok, cleaned}
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
    {explicit_extra_body, rest} = Map.pop(map, "extra_body")
    explicit_extra_body = if is_map(explicit_extra_body), do: explicit_extra_body, else: %{}

    {opts, promoted} =
      Enum.reduce(rest, {[], %{}}, fn {k, v}, {opts, promoted} ->
        case known_default_opt_key(k) do
          {:ok, atom} -> {[{atom, v} | opts], promoted}
          :error -> {opts, Map.put(promoted, k, v)}
        end
      end)

    extra_body = Map.merge(promoted, explicit_extra_body)

    if extra_body == %{}, do: opts, else: [{:extra_body, extra_body} | opts]
  end

  defp parse_default_opts(_) do
    []
  end

  # Checks whether `key` is one of the inference params req_llm recognizes as
  # real options (temperature, max_tokens, top_p, top_k, min_p,
  # receive_timeout, anthropic_prompt_cache, anthropic_prompt_cache_ttl — the
  # set documented in configuration.md's "Model params" table).
  #
  # Any other key found flat in a model's params map is not a req_llm option
  # at all — it's forwarded as-is into extra_body (merged verbatim into the
  # request's JSON body) rather than dropped, since which sampler knobs a
  # backend accepts (llama.cpp's repetition_penalty, vLLM's
  # chat_template_kwargs, ...) varies by model and arch and isn't something
  # Planck can enumerate. receive_timeout and anthropic_prompt_cache* are
  # excluded from that passthrough on purpose: they're consumed by req_llm
  # itself (an HTTP timeout, a cache-breakpoint flag) rather than sent to the
  # provider, so routing them into the request body would silently do nothing.
  #
  # Implemented as literal atom clauses rather than String.to_existing_atom/1:
  # that would depend on whether some unrelated module has already loaded a
  # matching atom literal, which is incidental VM state, not a real validity
  # check. Every atom here is guaranteed to exist because it is written
  # directly in this module.
  @spec known_default_opt_key(String.t()) :: {:ok, atom()} | :error
  defp known_default_opt_key(key)

  defp known_default_opt_key("temperature"), do: {:ok, :temperature}
  defp known_default_opt_key("max_tokens"), do: {:ok, :max_tokens}
  defp known_default_opt_key("top_p"), do: {:ok, :top_p}
  defp known_default_opt_key("top_k"), do: {:ok, :top_k}
  defp known_default_opt_key("min_p"), do: {:ok, :min_p}
  defp known_default_opt_key("receive_timeout"), do: {:ok, :receive_timeout}
  defp known_default_opt_key("anthropic_prompt_cache"), do: {:ok, :anthropic_prompt_cache}
  defp known_default_opt_key("anthropic_prompt_cache_ttl"), do: {:ok, :anthropic_prompt_cache_ttl}
  defp known_default_opt_key(_), do: :error
end
