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

  @typedoc "Supported LLM provider backends."
  @type provider :: :anthropic | :openai | :google

  @typedoc "Per-token cost in USD per million tokens."
  @type cost :: %{
          input: float(),
          output: float(),
          cache_read: float(),
          cache_write: float()
        }

  @typedoc """
  An LLM model struct.

  - `id` — user-facing alias (e.g. `"sonnet"`); used to look up the model in config.
  - `model` — actual API identifier sent to the provider (e.g. `"claude-sonnet-4-6"`);
    falls back to `id` when `nil` (legacy flat-config path).
  - `identifier` — uppercase env-var prefix for custom OpenAI-compat providers
    (e.g. `"NVIDIA"` → resolves `NVIDIA_API_KEY`).
  - `has_api_key` — when `false`, the adapter skips env-var lookup and sends
    `"not-needed"` as the API key (for local servers like llama.cpp).
  - `api_key` — not used at runtime; reserved for future in-memory overrides.
  """
  @type t :: %__MODULE__{
          id: String.t(),
          model: String.t() | nil,
          name: String.t(),
          provider: provider(),
          context_window: pos_integer(),
          max_tokens: pos_integer(),
          supports_thinking: boolean(),
          input_types: [:text | :image | :image_url | :file | :video_url],
          base_url: String.t() | nil,
          api_key: String.t() | nil,
          identifier: String.t() | nil,
          has_api_key: boolean(),
          cost: cost(),
          default_opts: keyword()
        }

  @providers [:anthropic, :openai, :google]

  @doc "Returns the list of supported provider atoms."
  @spec providers() :: [provider()]
  def providers, do: @providers

  defstruct [
    :id,
    :model,
    :name,
    :provider,
    :context_window,
    :max_tokens,
    :base_url,
    :api_key,
    :identifier,
    supports_thinking: false,
    has_api_key: true,
    input_types: [:text],
    cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
    default_opts: []
  ]
end
