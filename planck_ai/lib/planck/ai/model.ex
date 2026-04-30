defmodule Planck.AI.Model do
  @moduledoc """
  Represents an LLM model and its metadata.

  The `base_url` field is used for self-hosted or OpenAI-compatible endpoints
  (llama.cpp, vLLM, LM Studio). When `nil`, the provider's default endpoint is used.

  ## Examples

      iex> %Planck.AI.Model{
      ...>   id: "claude-sonnet-4-6",
      ...>   name: "Claude Sonnet 4.6",
      ...>   provider: :anthropic,
      ...>   context_window: 200_000,
      ...>   max_tokens: 8096,
      ...>   supports_thinking: true,
      ...>   input_types: [:text, :image]
      ...> }

  """

  @type provider :: :anthropic | :openai | :google | :ollama | :llama_cpp

  @type cost :: %{
          input: float(),
          output: float(),
          cache_read: float(),
          cache_write: float()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          provider: provider(),
          context_window: pos_integer(),
          max_tokens: pos_integer(),
          supports_thinking: boolean(),
          input_types: [:text | :image | :image_url | :file | :video_url],
          base_url: String.t() | nil,
          api_key: String.t() | nil,
          cost: cost(),
          default_opts: keyword()
        }

  defstruct [
    :id,
    :name,
    :provider,
    :context_window,
    :max_tokens,
    :base_url,
    :api_key,
    supports_thinking: false,
    input_types: [:text],
    cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
    default_opts: []
  ]
end
