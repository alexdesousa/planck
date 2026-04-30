defmodule Planck.AI.Context do
  @moduledoc """
  Everything sent to the LLM in a single request: system prompt, conversation
  history, and available tools.

  Inference parameters (temperature, max_tokens, etc.) are NOT stored here —
  they are passed as keyword options at the `Planck.AI.stream/3` or
  `Planck.AI.complete/3` call site and forwarded directly to `req_llm`.

  ## Examples

      iex> %Planck.AI.Context{
      ...>   system: "You are a helpful coding assistant.",
      ...>   messages: [
      ...>     %Planck.AI.Message{role: :user, content: [{:text, "Hello"}]}
      ...>   ],
      ...>   tools: []
      ...> }

  """

  @type t :: %__MODULE__{
          system: String.t() | nil,
          messages: [Planck.AI.Message.t()],
          tools: [Planck.AI.Tool.t()]
        }

  defstruct system: nil, messages: [], tools: []
end
