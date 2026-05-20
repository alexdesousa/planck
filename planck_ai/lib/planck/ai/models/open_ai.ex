defmodule Planck.AI.Models.OpenAI do
  @moduledoc """
  Model catalog for OpenAI and OpenAI-compatible endpoints.

  Without options, returns the LLMDB catalog for OpenAI's GPT family (requires
  `OPENAI_API_KEY`). With a `base_url:` option, queries the server's `/models`
  endpoint at call time — use this for NVIDIA NIM, Groq, Ollama, llama.cpp, etc.

  ## Examples

      # Cloud catalog
      Planck.AI.Models.OpenAI.all()

      # Custom endpoint
      Planck.AI.Models.OpenAI.all(
        base_url: "https://integrate.api.nvidia.com/v1",
        identifier: "NVIDIA"
      )

      # Build a single model struct
      Planck.AI.Models.OpenAI.model("meta/llama-3.3-70b-instruct",
        base_url: "https://integrate.api.nvidia.com/v1",
        identifier: "NVIDIA",
        context_window: 128_000
      )

  """

  @behaviour Planck.AI.ModelProvider

  require Logger

  alias Planck.AI.{LLMDB, Model}

  @doc """
  Returns models for this provider.

  Without `base_url:`, returns the LLMDB snapshot for OpenAI.
  With `base_url:`, queries the server's `/models` endpoint.

  ## Options (custom endpoint only)

  - `:base_url` — base URL of the server.
  - `:identifier` — uppercase tag for env var derivation (e.g. `"NVIDIA"` →
    `NVIDIA_API_KEY`). Defaults to `"OPENAI"`.
  - `:context_window` — default context window. Defaults to `4_096`.
  - `:max_tokens` — default max tokens. Defaults to `2_048`.
  """
  @spec all() :: [Model.t()]
  @spec all(keyword()) :: [Model.t()]
  @impl Planck.AI.ModelProvider
  def all(opts \\ []) do
    case opts[:base_url] do
      nil -> LLMDB.models(:openai)
      base_url -> query_endpoint(base_url, opts)
    end
  end

  defp query_endpoint(base_url, opts) do
    identifier = opts[:identifier] || "OPENAI"
    api_key = System.get_env("#{identifier}_API_KEY")
    req_opts = if api_key, do: [auth: {:bearer, api_key}], else: []

    case http_client().get("#{base_url}/models", req_opts) do
      {:ok, %{status: 200, body: %{"data" => models}}} ->
        Enum.map(models, &parse_model(&1, base_url, opts))

      {:ok, %{status: status}} ->
        Logger.warning("[Planck.AI] openai endpoint returned HTTP #{status} from #{base_url}")
        []

      {:error, reason} ->
        Logger.warning(
          "[Planck.AI] openai endpoint unreachable at #{base_url}: #{inspect(reason)}"
        )

        []
    end
  end

  defp parse_model(%{"id" => id}, base_url, opts) do
    %Model{
      id: id,
      name: id,
      provider: :openai,
      identifier: opts[:identifier],
      base_url: base_url,
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
