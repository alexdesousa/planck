defmodule Planck.AI.Models.LlamaCpp do
  @moduledoc """
  Factory for llama.cpp models via its OpenAI-compatible HTTP server.

  Unlike other catalog modules, this provides a factory function rather than
  a static list because the available model depends on what the user has loaded
  into their local llama.cpp server.

  ## Examples

      iex> Planck.AI.Models.LlamaCpp.model("llama3.2")
      %Planck.AI.Model{provider: :llama_cpp, base_url: "http://localhost:8080", ...}

      iex> Planck.AI.Models.LlamaCpp.model("mistral", base_url: "http://10.0.0.5:8080", context_window: 32_768)

  """

  @behaviour Planck.AI.ModelProvider

  require Logger

  alias Planck.AI.Model

  @default_base_url "http://localhost:8080"

  @spec all() :: [Model.t()]
  @spec all(keyword()) :: [Model.t()]
  @impl Planck.AI.ModelProvider
  def all(opts \\ []) do
    base_url = opts[:base_url] || @default_base_url
    req_opts = if api_key = opts[:api_key], do: [auth: {:bearer, api_key}], else: []

    case http_client().get("#{base_url}/models", req_opts) do
      {:ok, %{status: 200, body: %{"data" => models}}} ->
        Enum.map(models, &parse_model(&1, base_url, opts))

      {:ok, %{status: status}} ->
        Logger.warning("[Planck.AI] llama.cpp returned HTTP #{status} from #{base_url}")
        []

      {:error, reason} ->
        Logger.warning("[Planck.AI] llama.cpp unreachable at #{base_url}: #{inspect(reason)}")
        []
    end
  end

  @doc """
  Builds a `Planck.AI.Model` for a llama.cpp-hosted model.

  ## Options

  - `:base_url` — base URL of the llama.cpp server. Defaults to `#{@default_base_url}`.
  - `:context_window` — context window size. Defaults to `4096`.
  - `:max_tokens` — max tokens to generate. Defaults to `2048`.
  - `:supports_thinking` — whether the model supports thinking blocks. Defaults to `false`.
  - `:input_types` — list of supported input modalities. Defaults to `[:text]`.
  - `:default_opts` — inference parameters applied on every call unless overridden by the
    caller (e.g. `[temperature: 1.0, top_p: 0.95, top_k: 40, min_p: 0.01]`). Defaults to `[]`.
  """
  @spec model(String.t()) :: Model.t()
  @spec model(String.t(), keyword()) :: Model.t()
  def model(id, opts \\ []) do
    %Model{
      id: id,
      name: opts[:name] || id,
      provider: :llama_cpp,
      base_url: opts[:base_url] || @default_base_url,
      api_key: opts[:api_key],
      context_window: opts[:context_window] || 4_096,
      max_tokens: opts[:max_tokens] || 2_048,
      supports_thinking: opts[:supports_thinking] || false,
      input_types: opts[:input_types] || [:text],
      default_opts: opts[:default_opts] || []
    }
  end

  defp parse_model(%{"id" => id}, base_url, opts) do
    %Model{
      id: id,
      name: id,
      provider: :llama_cpp,
      base_url: base_url,
      api_key: opts[:api_key],
      context_window: opts[:context_window] || 4_096,
      max_tokens: opts[:max_tokens] || 2_048,
      supports_thinking: opts[:supports_thinking] || false,
      input_types: opts[:input_types] || [:text],
      default_opts: opts[:default_opts] || []
    }
  end

  defp http_client do
    Application.get_env(:planck_ai, :http_client, Planck.AI.ReqHTTPClient)
  end
end
