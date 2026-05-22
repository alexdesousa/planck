defmodule Sidecar.SkillReflector.Prompt do
  @moduledoc """
  Builds the system prompt for the SkillReflector's ephemeral mini-agent.
  """

  alias Planck.Agent.Message

  @doc """
  Build the reflector system prompt given the completed turn's messages and the
  parent agent's name (used to label assistant messages in the turn summary).
  """
  @spec build([Message.t()], String.t()) :: String.t()
  def build(turn_messages, agent_name) do
    turn_summary = format_turn(turn_messages, agent_name)

    """
    You are a skill curator for an AI coding assistant. Your job is to evaluate
    whether the completed turn below represents a reusable workflow worth
    capturing as a skill.

    ## Your tools

    - `list_skills` — lists all skills you have previously written. **Always call
      this first** before deciding whether to create or update.
    - `load_skill` — loads the full content of a skill by name.
    - `write_skill` — writes or updates a skill.

    ## Process

    1. Call `list_skills` to see what agent-created skills already exist.
    2. Review the completed turn to identify the core workflow performed.
    3. Decide: is this workflow repeatable and non-obvious?
    4. If yes and a similar skill already exists → load it, then update it with
       any new steps or improvements.
    5. If yes and no similar skill exists → write a new one.
    6. If no → end your turn without writing anything.

    ## When to capture a skill

    **Capture** when the turn shows:
    - A multi-step, repeatable workflow with a clear pattern
    - Steps that are non-obvious or require specific knowledge about the project
    - A procedure that would plausibly be needed again

    **Skip** when the turn shows:
    - Highly project-specific edits (e.g., changing one value in a specific file)
    - A trivial or single-step task
    - Something already covered by an existing skill

    ## Skill structure

    Use exactly these sections in the skill body:

    ### When to Use
    Describe the specific situations that call for this skill. Be precise about triggers.

    ### Quick Reference
    Key commands, paths, patterns, or constants needed at a glance.

    ### Procedure
    Numbered step-by-step instructions precise enough to reproduce the same result.

    ### Pitfalls
    Common mistakes, edge cases, or things that can go wrong.

    ### Verification
    How to confirm the procedure succeeded.

    ## Completed turn

    #{turn_summary}
    """
    |> String.trim()
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec format_turn([Message.t()], String.t()) :: String.t()
  defp format_turn(messages, agent_name) do
    messages
    |> Enum.map(&format_message(&1, agent_name))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @spec format_message(Message.t(), String.t()) :: String.t()
  defp format_message(%Message{role: :user, content: content}, _agent_name) do
    case extract_text(content) do
      "" -> ""
      text -> "**User:** #{text}"
    end
  end

  defp format_message(%Message{role: :assistant, content: content}, agent_name) do
    text = extract_text(content)
    calls = extract_tool_calls(content)

    parts =
      [
        if(text != "", do: "**#{agent_name}:** #{text}", else: nil),
        if(calls != [], do: Enum.join(calls, "\n"), else: nil)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, "\n")
  end

  defp format_message(%Message{role: :tool_result, content: content}, _agent_name) do
    results =
      content
      |> Enum.flat_map(fn
        {:tool_result, _id, value} -> [truncate(value, 300)]
        _ -> []
      end)

    case results do
      [] -> ""
      _ -> "**Result:** " <> Enum.join(results, " | ")
    end
  end

  defp format_message(
         %Message{role: {:custom, :agent_response}, content: content, metadata: meta},
         _agent_name
       ) do
    case extract_text(content) do
      "" -> ""
      text -> "**#{Map.get(meta, :sender_name, "agent")}:** #{text}"
    end
  end

  defp format_message(_msg, _agent_name), do: ""

  @spec extract_text([Planck.AI.Message.content_part()]) :: String.t()
  defp extract_text(content) do
    content
    |> Enum.flat_map(fn
      {:text, text} -> [text]
      _ -> []
    end)
    |> IO.iodata_to_binary()
    |> String.trim()
  end

  @spec extract_tool_calls([Planck.AI.Message.content_part()]) :: [String.t()]
  defp extract_tool_calls(content) do
    Enum.flat_map(content, fn
      {:tool_call, _id, name, args} ->
        args_summary =
          args
          |> Map.take(~w(command path name file))
          |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{truncate(inspect(v), 60)}" end)

        ["**Tool:** `#{name}`#{if args_summary != "", do: " (#{args_summary})", else: ""}"]

      _ ->
        []
    end)
  end

  @spec truncate(String.t(), pos_integer()) :: String.t()
  defp truncate(str, max) do
    if String.length(str) > max do
      String.slice(str, 0, max) <> "…"
    else
      str
    end
  end
end
