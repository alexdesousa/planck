defmodule Planck.Agent.MessageBuilder do
  @moduledoc """
  Pure functions for constructing `Planck.Agent.Message` values.

  No side effects — these functions take raw data and return messages.
  Used by `Planck.Agent` to build assistant and tool-result messages
  during the LLM loop.
  """

  alias Planck.Agent.{Message, StreamBuffer}

  @max_tool_output_lines 2_000
  @max_tool_output_bytes 50_000

  @doc """
  Normalize a user prompt to a list of content parts.

  A plain string is wrapped in a `{:text, text}` tuple. A list is
  returned as-is.
  """
  @spec normalize_content(String.t() | [Planck.AI.Message.content_part()]) ::
          [Planck.AI.Message.content_part()]
  def normalize_content(text)
  def normalize_content(text) when is_binary(text), do: [{:text, text}]
  def normalize_content(parts) when is_list(parts), do: parts

  @doc """
  Build an assistant message from a `StreamBuffer`.

  Content order: thinking → text → tool calls. Fields that are empty strings
  or empty lists are omitted from the message content.
  """
  @spec build_assistant(StreamBuffer.t()) :: Message.t()
  def build_assistant(stream_buffer)

  def build_assistant(%StreamBuffer{text: text, thinking: thinking, calls: calls}) do
    content =
      Enum.map(calls, fn %{id: id, name: name, args: args} -> {:tool_call, id, name, args} end)
      |> prepend_if(text != "", {:text, text})
      |> prepend_if(thinking != "", {:thinking, thinking})

    Message.new(:assistant, content)
  end

  @doc """
  Build a tool-result message from a list of `{call_id, result}` pairs.

  Results must be in `{:ok, string} | {:error, reason}` form. Each value is
  truncated to #{@max_tool_output_lines} lines / #{@max_tool_output_bytes} bytes.
  """
  @spec build_tool_result([{String.t(), {:ok, String.t()} | {:error, term()}}]) :: Message.t()
  def build_tool_result(results)

  def build_tool_result(results) when is_list(results) do
    content =
      Enum.map(results, fn {id, result} ->
        value =
          case result do
            {:ok, v} when is_binary(v) -> v
            {:ok, v} -> inspect(v)
            {:error, reason} when is_binary(reason) -> "Error: #{reason}"
            {:error, reason} -> "Error: #{inspect(reason)}"
          end

        {:tool_result, id, truncate_tool_output(value)}
      end)

    Message.new(:tool_result, content)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec truncate_tool_output(String.t()) :: String.t()
  defp truncate_tool_output(value)

  defp truncate_tool_output(value) when is_binary(value) do
    if String.valid?(value) do
      truncate_text_output(value)
    else
      "[binary file, #{byte_size(value)} bytes — cannot display]"
    end
  end

  @spec truncate_text_output(String.t()) :: String.t()
  defp truncate_text_output(value)

  defp truncate_text_output(value) when is_binary(value) do
    lines = String.split(value, "\n")

    {value, line_truncated} =
      if length(lines) > @max_tool_output_lines do
        {Enum.take(lines, @max_tool_output_lines) |> Enum.join("\n"), true}
      else
        {value, false}
      end

    {value, truncated} =
      if byte_size(value) > @max_tool_output_bytes do
        {binary_part(value, 0, @max_tool_output_bytes), true}
      else
        {value, line_truncated}
      end

    if truncated, do: value <> "\n[output truncated]", else: value
  end

  @spec prepend_if(list(), boolean(), term()) :: list()
  defp prepend_if(list, condition, item)
  defp prepend_if(list, true, item), do: [item | list]
  defp prepend_if(list, false, _item), do: list
end
