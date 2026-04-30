defmodule Planck.AI.Models.Ollama do
  @moduledoc """
  Factory for Ollama models via its OpenAI-compatible HTTP server.

  Like llama.cpp, the available models depend on what has been pulled into the
  local Ollama instance, so this module provides a factory rather than a static
  catalog.

  ## Examples

      iex> Planck.AI.Models.Ollama.model("llama3.2")
      %Planck.AI.Model{provider: :ollama, base_url: "http://localhost:11434", ...}

      iex> Planck.AI.Models.Ollama.model("qwen2.5-coder:7b",
      ...>   base_url: "http://10.0.0.5:11434",
      ...>   context_window: 32_768
      ...> )

  """

  @behaviour Planck.AI.ModelProvider

  require Logger

  alias Planck.AI.Model

  @default_base_url "http://localhost:11434"

  @spec all() :: [Model.t()]
  @spec all(keyword()) :: [Model.t()]
  @impl Planck.AI.ModelProvider
  def all(opts \\ []) do
    base_url = opts[:base_url] || @default_base_url

    case http_client().get("#{base_url}/api/tags", []) do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        Enum.map(models, &parse_model(&1, base_url))

      {:ok, %{status: status}} ->
        Logger.warning("[Planck.AI] Ollama returned HTTP #{status} from #{base_url}")
        []

      {:error, reason} ->
        Logger.warning("[Planck.AI] Ollama unreachable at #{base_url}: #{inspect(reason)}")
        []
    end
  end

  @doc """
  Builds a `Planck.AI.Model` for an Ollama-hosted model.

  ## Options

  - `:base_url` — base URL of the Ollama server. Defaults to `#{@default_base_url}`.
  - `:context_window` — context window size. Defaults to `4096`.
  - `:max_tokens` — max tokens to generate. Defaults to `2048`.
  - `:supports_thinking` — whether the model supports thinking blocks. Defaults to `false`.
  - `:input_types` — list of supported input modalities. Defaults to `[:text]`.
  - `:default_opts` — inference parameters applied on every call unless overridden by the
    caller (e.g. `[temperature: 0.8, top_p: 0.9]`). Defaults to `[]`.
  """
  @spec model(String.t()) :: Model.t()
  @spec model(String.t(), keyword()) :: Model.t()
  def model(id, opts \\ []) do
    %Model{
      id: id,
      name: opts[:name] || id,
      provider: :ollama,
      base_url: opts[:base_url] || @default_base_url,
      context_window: opts[:context_window] || 4_096,
      max_tokens: opts[:max_tokens] || 2_048,
      supports_thinking: opts[:supports_thinking] || false,
      input_types: opts[:input_types] || [:text],
      default_opts: opts[:default_opts] || []
    }
  end

  defp parse_model(%{"name" => name} = raw, base_url) do
    %Model{
      id: name,
      name: display_name(name, raw),
      provider: :ollama,
      base_url: base_url,
      context_window: 4_096,
      max_tokens: 2_048,
      input_types: [:text]
    }
  end

  defp display_name(name, %{"details" => %{"parameter_size" => size}}) when is_binary(size) do
    base = name |> String.split(":") |> hd()
    "#{base} (#{size})"
  end

  defp display_name(name, _), do: name

  defp http_client do
    Application.get_env(:planck_ai, :http_client, Planck.AI.ReqHTTPClient)
  end
end
