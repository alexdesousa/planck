defmodule Planck.AI.Models.TypeSafe do
  @moduledoc """
  Model catalog for Typesafe AI's System One models and Typesafe-compatible
  endpoints.

  Unlike `Planck.AI.Models.OpenAI`, there is no bundled LLMDB catalog for
  `:typesafe` — this provider queries `GET "\#{base_url}/v1/models"` at call
  time, cloud or self-hosted, since both expose the same path per Typesafe's
  API reference. A self-hosted/compatible server that doesn't implement
  discovery (e.g. `decider`) degrades to `[]`, the same as any other
  non-200 or unreachable response.

  ## Examples

      # Cloud catalog (TYPESAFE_API_KEY)
      Planck.AI.Models.TypeSafe.all()

      # Self-hosted / compatible endpoint
      Planck.AI.Models.TypeSafe.all(base_url: "http://localhost:8377")

  """
  @behaviour Planck.AI.ModelProvider

  require Logger

  alias Planck.AI.Model

  @default_base_url "https://api.typesafe.ai"

  @doc """
  Returns models for this provider by querying `GET /v1/models` at
  `base_url` (defaults to Typesafe's cloud API).

  ## Options

  - `:base_url` — base URL of the server. Defaults to `#{@default_base_url}`.
  - `:identifier` — uppercase tag for env var derivation (e.g. `"JEV"` →
    `JEV_API_KEY`). Defaults to `"TYPESAFE"`.
  - `:context_window` — default context window. Defaults to `32_768`.
  - `:max_tokens` — default max tokens. Defaults to `2_048`.
  """
  @spec all() :: [Model.t()]
  @spec all(keyword()) :: [Model.t()]
  @impl Planck.AI.ModelProvider
  def all(opts \\ [])

  def all(opts) when is_list(opts) do
    base_url = opts[:base_url] || @default_base_url
    identifier = opts[:identifier] || "TYPESAFE"
    api_key = System.get_env("#{identifier}_API_KEY")
    req_opts = if api_key, do: [auth: {:bearer, api_key}], else: []

    case http_client().get("#{base_url}/v1/models", req_opts) do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        Enum.map(models, &parse_model(&1, base_url, opts))

      {:ok, %{status: status}} ->
        message = "[Planck.AI] typesafe endpoint returned HTTP #{status} from #{base_url}"
        Logger.warning(message)
        []

      {:error, reason} ->
        message = "[Planck.AI] typesafe endpoint unreachable at #{base_url}: #{inspect(reason)}"
        Logger.warning(message)
        []
    end
  end

  @spec parse_model(map(), String.t(), keyword()) :: Model.t()
  defp parse_model(params, base_url, opts)

  defp parse_model(%{"name" => name}, base_url, opts) do
    %Model{
      id: name,
      name: name,
      provider: :typesafe,
      type: :rlcd,
      identifier: opts[:identifier],
      base_url: base_url,
      context_window: opts[:context_window] || 32_768,
      max_tokens: opts[:max_tokens] || 2_048,
      supports_thinking: opts[:supports_thinking] || false,
      input_types: opts[:input_types] || [:text],
      default_opts: opts[:default_opts] || []
    }
  end

  @spec http_client() :: module()
  defp http_client do
    Application.get_env(:planck_ai, :http_client, Planck.AI.ReqHTTPClient)
  end
end
