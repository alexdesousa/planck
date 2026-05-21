defmodule Sidecar.Tools.UpdateMemory do
  @moduledoc """
  Appends a new fact to the agent's persistent short-term memory.

  ## Behaviour

  1. Load the current memory from Typesense.
  2. Append the new fact to the existing content.
  3. If the combined length is within `@max_chars` — write directly.
  4. If it exceeds the limit — return an error containing the full combined
     content so the agent (LLM) can summarize and resubmit a consolidated
     version via a second `update_memory` call.

  The size check keeps memory lean and forces periodic consolidation, with the
  LLM doing the summarization rather than the tool.
  """

  @max_size 2_200

  @doc "Returns the `update_memory` tool definition."
  @spec tool() :: Planck.Agent.Tool.t()
  def tool do
    Planck.Agent.Tool.new(
      name: "update_memory",
      description:
        "Update your persistent memory. " <>
          "Use `append` (default) to add a new fact — if memory is full you will " <>
          "receive the combined content to summarize. " <>
          "Use `overwrite` to replace the entire memory with a consolidated summary " <>
          "after receiving a full-memory error.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "content" => %{
            "type" => "string",
            "description" =>
              "The fact to append, or the full consolidated memory when overwriting."
          },
          "action" => %{
            "type" => "string",
            "enum" => ["append", "overwrite"],
            "description" =>
              "\"append\" adds to existing memory (default); \"overwrite\" replaces it entirely."
          }
        },
        "required" => ["content"]
      },
      execute_fn: fn agent_id, _id, args ->
        action = Map.get(args, "action", "append")

        case action do
          "overwrite" -> overwrite_memory(agent_id, args)
          _ -> append_memory(agent_id, args)
        end
      end
    )
  end

  # ---------------------------------------------------------------------------

  @spec overwrite_memory(String.t(), map()) ::
          {:ok, String.t()}
          | {:error, String.t()}
  defp overwrite_memory(agent_id, args)

  defp overwrite_memory(agent_id, args) do
    content = args["content"]
    {agent_key, session_id} = resolve_agent_info(agent_id)

    write_memory(agent_key, session_id, content)
  end

  @spec append_memory(String.t(), map()) ::
          {:ok, String.t()}
          | {:error, String.t()}

  defp append_memory(agent_id, args)

  defp append_memory(agent_id, args) do
    content = args["content"]
    {agent_key, session_id} = resolve_agent_info(agent_id)
    existing = Sidecar.Memory.current(agent_key) || ""

    combined =
      if existing == "",
        do: content,
        else: existing <> "\n\n" <> content

    maybe_write_memory(agent_key, session_id, combined)
  end

  @spec resolve_agent_info(String.t()) :: {String.t(), String.t() | nil}
  defp resolve_agent_info(agent_id) do
    case Planck.Agent.whereis(agent_id) do
      {:ok, pid} ->
        state = Planck.Agent.get_state(pid)
        agent_key = "#{state.team_name}:#{state.name}"
        {agent_key, state.session_id}

      _ ->
        {agent_id, nil}
    end
  end

  @spec maybe_write_memory(String.t(), String.t() | nil, String.t()) ::
          {:ok, String.t()}
          | {:error, String.t()}
  defp maybe_write_memory(agent_key, session_id, content) do
    size = memory_size(content)

    if size < @max_size do
      write_memory(agent_key, session_id, content)
    else
      {:error,
       "Memory is full (#{size} / #{@max_size} chars). " <>
         "Summarize the following and call update_memory with action \"overwrite\":\n\n" <>
         content}
    end
  end

  @spec write_memory(String.t(), String.t(), String.t()) ::
          {:ok, String.t()}
          | {:error, String.t()}
  defp write_memory(agent_key, session_id, content) do
    case Sidecar.Memory.write(agent_key, session_id, content) do
      :ok -> {:ok, "Memory replaced."}
      {:error, reason} -> {:error, "Failed to update memory: #{reason}"}
    end
  end

  @spec memory_size(String.t()) :: non_neg_integer()
  defp memory_size(text) do
    text
    |> String.split("\n", trim: true)
    |> Stream.map(&String.length/1)
    |> Enum.sum()
  end
end
