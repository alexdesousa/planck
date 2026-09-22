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

  @doc """
  Rough token estimate for the *entire* request this context represents —
  system prompt, conversation, and tool schemas.

  A live "how much context is used" figure needs all three: the system
  prompt alone is routinely the largest single piece (tool guidance,
  skills, `AGENTS.md`), and tool schemas sent on every request can be
  substantial too once several tools are registered — estimating only the
  conversation messages undercounts by everything actually sent alongside
  them. This is the actual `t()` about to be (or just was) sent, not a
  reconstruction of it from separate pieces that can drift out of sync
  with each other. This is also the one place per-content-part token
  counting is written — a caller holding `Planck.Agent.Message.t()` structs
  converts via `Planck.Agent.Message.to_ai_messages/1` and wraps the result
  in a bare `%__MODULE__{}` (`system`/`tools` left at their defaults for a
  messages-only estimate) rather than duplicating this logic for its own
  message type.
  """
  @spec estimate_tokens(t()) :: non_neg_integer()
  def estimate_tokens(%__MODULE__{system: system, messages: messages, tools: tools}) do
    estimate_text(system) + estimate_messages(messages) + estimate_tools(tools)
  end

  @spec estimate_text(String.t() | nil) :: non_neg_integer()
  defp estimate_text(nil), do: 0
  defp estimate_text(text), do: div(String.length(text), 4)

  @spec estimate_messages([Planck.AI.Message.t()]) :: non_neg_integer()
  defp estimate_messages(messages) do
    Enum.reduce(messages, 0, fn %Planck.AI.Message{content: content}, acc ->
      Enum.reduce(content, acc, &(&2 + estimate_message(&1)))
    end)
  end

  @spec estimate_message(Planck.AI.Message.content_part()) :: non_neg_integer()
  defp estimate_message(content_part)

  defp estimate_message({:text, text}), do: div(String.length(text), 4)
  defp estimate_message({:thinking, text}), do: div(String.length(text), 4)
  defp estimate_message({:tool_result, _id, value}), do: div(String.length(value), 4)

  defp estimate_message({:tool_call, _id, name, args}) do
    div(String.length(name) + String.length(inspect(args)), 4)
  end

  defp estimate_message(_other), do: 0

  # Tools are stable for the life of a turn but not free — a schema-heavy
  # tool list is real request payload, not overhead to round down to zero.
  @spec estimate_tools([Planck.AI.Tool.t()]) :: non_neg_integer()
  defp estimate_tools([]), do: 0

  defp estimate_tools(tools) do
    tools
    |> Enum.map(&Map.from_struct/1)
    |> Jason.encode!()
    |> String.length()
    |> div(4)
  end
end
