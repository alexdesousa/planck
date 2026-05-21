defmodule Planck.Agent.StreamBuffer do
  @moduledoc """
  Accumulates the output of a single LLM stream turn.

  Text deltas, thinking deltas, and tool call completions are appended as the
  stream arrives. At stream end the buffer is consumed to build the assistant
  message and hand off tool calls for execution.
  """

  @typedoc """
  - `:text` — accumulated text content from `:text_delta` events
  - `:thinking` — accumulated thinking content from `:thinking_delta` events
  - `:calls` — completed tool calls from `:tool_call_complete` events, in order
  """
  @type t :: %__MODULE__{
          text: String.t(),
          thinking: String.t(),
          calls: [map()]
        }

  defstruct text: "", thinking: "", calls: []

  @doc "Return an empty buffer."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Append a text delta."
  @spec append_text(t(), String.t()) :: t()
  def append_text(stream_buffer, text)
  def append_text(%__MODULE__{} = buf, text), do: %{buf | text: buf.text <> text}

  @doc "Append a thinking delta."
  @spec append_thinking(t(), String.t()) :: t()
  def append_thinking(stream_buffer, text)
  def append_thinking(%__MODULE__{} = buf, text), do: %{buf | thinking: buf.thinking <> text}

  @doc "Add a completed tool call."
  @spec add_call(t(), map()) :: t()
  def add_call(stream_buffer, call)
  def add_call(%__MODULE__{} = buf, call), do: %{buf | calls: buf.calls ++ [call]}
end
