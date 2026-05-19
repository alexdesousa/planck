defmodule Planck.AI.Models.CustomOpenAI do
  @moduledoc """
  Factory and discovery for OpenAI-compatible endpoints (e.g. NVIDIA, Together,
  vLLM, LM Studio).

  Unlike cloud provider modules, this queries the running server at call time
  because the available models depend on the specific endpoint.

  ## Examples

      iex> Planck.AI.Models.CustomOpenAI.model("meta/llama-3.1-8b-instruct",
      ...>   identifier: "nvidia",
      ...>   base_url: "https://integrate.api.nvidia.com/v1",
      ...>   context_window: 128_000
      ...> )
      %Planck.AI.Model{provider: :custom_openai, identifier: "nvidia", ...}

  """

  @behaviour Planck.AI.ModelProvider

  require Logger

  alias Planck.AI.Model

  @doc """
  Discovers models from an OpenAI-compatible `/models` endpoint.

  ## Options

  - `:base_url` — base URL of the server (required).
  - `:api_key` — bearer token sent as `Authorization: Bearer <key>`.
  - `:identifier` — name used to identify this endpoint (e.g. `"nvidia"`).
    Stored on each returned model.
  - `:context_window` — default context window for discovered models. Defaults to `4_096`.
  - `:max_tokens` — default max tokens. Defaults to `2_048`.
  """
  @spec all() :: [Model.t()]
  @spec all(keyword()) :: [Model.t()]
  @impl Planck.AI.ModelProvider
  def all(opts \\ []) do
    base_url = opts[:base_url] || ""
    api_key = opts[:api_key]
    req_opts = if api_key, do: [auth: {:bearer, api_key}], else: []

    case http_client().get("#{base_url}/models", req_opts) do
      {:ok, %{status: 200, body: %{"data" => models}}} ->
        Enum.map(models, &parse_model(&1, base_url, opts))

      {:ok, %{status: status}} ->
        Logger.warning("[Planck.AI] custom_openai returned HTTP #{status} from #{base_url}")
        []

      {:error, reason} ->
        Logger.warning("[Planck.AI] custom_openai unreachable at #{base_url}: #{inspect(reason)}")
        []
    end
  end

  @doc """
  Builds a `Planck.AI.Model` for a custom OpenAI-compatible endpoint.

  ## Options

  - `:identifier` — name used to identify this endpoint (e.g. `"nvidia"`).
  - `:base_url` — base URL of the server.
  - `:api_key` — bearer token for authentication.
  - `:name` — display name. Defaults to `id`.
  - `:context_window` — context window size. Defaults to `4_096`.
  - `:max_tokens` — max tokens to generate. Defaults to `2_048`.
  - `:supports_thinking` — whether the model supports thinking blocks. Defaults to `false`.
  - `:input_types` — list of supported input modalities. Defaults to `[:text]`.
  - `:default_opts` — inference parameters applied on every call. Defaults to `[]`.
  """
  @spec model(String.t()) :: Model.t()
  @spec model(String.t(), keyword()) :: Model.t()
  def model(id, opts \\ []) do
    %Model{
      id: id,
      name: opts[:name] || id,
      provider: :custom_openai,
      identifier: opts[:identifier],
      base_url: opts[:base_url],
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
      provider: :custom_openai,
      identifier: opts[:identifier],
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
