defmodule Planck.Agent.SystemPrompt do
  @moduledoc """
  Assembles the runtime system prompt for an agent.

  Called before every LLM turn by the agent's private `build_system_prompt` function.
  Sections are added only when the relevant tools are present in the agent's
  tool map, so agents only receive guidance for what they can actually do.

  ## Assembly order

  1. Identity line — "You are a <type>." / "You are <name>, a <type>."
  2. Base system prompt from `spec.system_prompt`
  3. Per-tool guidance sections (one per inter-agent tool present)
  4. Skills section (from `skill_refresh_fn` if present)
  """

  alias Planck.Agent.{Skill, Tool}

  @typedoc "Fields extracted from the agent state needed to build the prompt."
  @type opts :: %{
          system_prompt: String.t(),
          name: String.t() | nil,
          type: String.t() | nil,
          tools: %{String.t() => Tool.t()},
          skill_names: [String.t()],
          skill_refresh_fn: (-> [Skill.t()]) | nil
        }

  # Inter-agent tools in the order their sections should appear.
  # Grouped: discovery → spawn → interaction → management.
  @ordered_tools ~w(
    list_team
    list_skills
    load_skill
    list_models
    spawn_agent
    call_agent
    send_agent
    respond_agent
    interrupt_agent
    destroy_agent
  )

  @doc """
  Build the full system prompt for an agent turn.
  """
  @spec build(opts()) :: String.t()
  def build(%{
        system_prompt: base,
        name: name,
        type: type,
        tools: tools,
        skill_names: names,
        skill_refresh_fn: refresh_fn
      }) do
    base
    |> prepend_identity_line(name, type)
    |> append_tool_sections(tools)
    |> append_skills(names, refresh_fn)
  end

  # ---------------------------------------------------------------------------
  # Identity
  # ---------------------------------------------------------------------------

  @spec prepend_identity_line(String.t(), String.t() | nil, String.t() | nil) :: String.t()
  defp prepend_identity_line(prompt, nil, nil), do: prompt

  defp prepend_identity_line(prompt, name, type) do
    line =
      cond do
        is_binary(name) and is_binary(type) and name != type -> "You are #{name}, a #{type}."
        is_binary(type) -> "You are a #{type}."
        true -> "You are #{name}."
      end

    "#{line}\n\n" <> prompt
  end

  # ---------------------------------------------------------------------------
  # Tool sections
  # ---------------------------------------------------------------------------

  @spec append_tool_sections(String.t(), %{String.t() => Tool.t()}) :: String.t()
  defp append_tool_sections(prompt, tools) do
    sections =
      @ordered_tools
      |> Enum.filter(&Map.has_key?(tools, &1))
      |> Enum.map(&tool_section/1)
      |> Enum.reject(&(&1 == ""))

    case sections do
      [] ->
        prompt

      _ ->
        block = Enum.join([inter_agent_intro(tools) | sections], "\n\n")
        append_section(prompt, block)
    end
  end

  @spec inter_agent_intro(%{String.t() => Tool.t()}) :: String.t()
  defp inter_agent_intro(tools) do
    has_delegate = Map.has_key?(tools, "send_agent")
    has_ask = Map.has_key?(tools, "call_agent")

    patterns =
      cond do
        has_ask and has_delegate ->
          """

          To choose between the two delegation patterns:

          - **Need the answer before continuing** → `call_agent` (blocks until the target responds)
          - **Can end your turn and wait** → `send_agent` (async; result arrives in a future turn via `respond_agent`)
          """

        has_ask ->
          "\n\n`call_agent` blocks until the target responds — your turn resumes with the answer."

        has_delegate ->
          "\n\n`send_agent` is async — end your turn after sending; the result arrives in a future turn via `respond_agent`."

        true ->
          ""
      end

    """
    ## Inter-agent tools

    Always target a **different** agent — never ask or delegate to yourself.#{patterns}
    """
    |> String.trim_trailing()
  end

  @spec tool_section(String.t()) :: String.t()

  defp tool_section("list_team") do
    """
    ### list_team

    Use when you need to find an agent's ID before targeting it, or to check who
    is currently in the team and their status (idle, streaming, or executing tools).
    The `id` field in the response is what you pass to `call_agent`, `send_agent`,
    `interrupt_agent`, and `destroy_agent`.
    Pass `verbose: true` to also see each member's tools and model.
    """
    |> String.trim_trailing()
  end

  defp tool_section("list_skills") do
    """
    ### list_skills

    Use when you need to discover what skills are available. Returns each skill's
    name and a short description of when to invoke it. Call this before `load_skill`
    if you are unsure which skill applies.
    """
    |> String.trim_trailing()
  end

  defp tool_section("load_skill") do
    """
    ### load_skill

    Use when a skill is relevant to your current task. Loads the full instructions
    for that skill by name. Call `list_skills` first if you don't know the exact name.
    """
    |> String.trim_trailing()
  end

  defp tool_section("list_models") do
    """
    ### list_models

    Use before spawning a new agent to see which models are available, their IDs,
    and the base_url required for local providers. Your current model is marked
    `current: true`.
    """
    |> String.trim_trailing()
  end

  defp tool_section("spawn_agent") do
    """
    ### spawn_agent

    Use when you need a new specialist in the team. Before calling it:

    1. Call `list_team` — check who is already there and save existing IDs for reuse.
    2. Call `list_models` — pick a model suited to the worker's task.

    Always grant the tools the worker needs via the `tools` parameter (e.g.
    `["read", "bash", "edit"]`). A worker spawned without tools cannot do useful work.
    Use `skills` to attach skill context — call `list_skills` first to see what is available.

    Multiple agents of the same type are allowed — e.g. two developers working on
    different features in parallel. Save the returned ID; you will need it to
    call_agent or send_agent to that specific worker.
    """
    |> String.trim_trailing()
  end

  defp tool_section("call_agent") do
    """
    ### call_agent

    Use when you need another agent's answer before you can continue (sync, blocking).
    Pass the target's `agent_id` from `list_team`. Blocks until the target responds,
    then your turn resumes with the answer. If the target is already busy, your
    question is queued — it will not be lost. Never target yourself.

    Pass `reset_previous_context: true` to archive the target's prior history and
    start it fresh before sending the question.
    """
    |> String.trim_trailing()
  end

  defp tool_section("send_agent") do
    """
    ### send_agent

    Use when you can hand off work without needing the result right away (async, fire-and-forget).
    Pass the target's `agent_id` from `list_team`.
    You can call `send_agent` multiple times in the same turn to fan out
    work across several agents in parallel — each will run concurrently.
    **After firing all sends, end your turn.**

    Each worker calls `respond_agent` when done, re-triggering a new turn for
    you. If you sent to N workers, you will be re-triggered N times — once
    per response. Plan to accumulate results across those turns rather than
    treating the first response as final.

    Pass `reset_previous_context: true` to archive the target's prior history and
    start it fresh before sending the task.
    Never send to yourself.
    """
    |> String.trim_trailing()
  end

  defp tool_section("respond_agent") do
    """
    ### respond_agent

    Use when you have finished your work and must report back to the agent that
    assigned you the task. Always call this before ending your turn — the caller
    is waiting. Include your full results or output in the response, not just a
    status message like "done". Never respond to yourself.
    """
    |> String.trim_trailing()
  end

  defp tool_section("interrupt_agent") do
    """
    ### interrupt_agent

    Use when a worker should stop what it is doing but you plan to reuse it soon
    — for example, to redirect it to a higher-priority task. The worker returns
    to idle and can receive a new task immediately. Prefer this over `destroy_agent`
    when the worker type is still useful.
    """
    |> String.trim_trailing()
  end

  defp tool_section("destroy_agent") do
    """
    ### destroy_agent

    Use when a worker is no longer needed at all. Permanently removes it from the
    team. Prefer `interrupt_agent` if you might reuse the worker later — spawning
    a replacement costs another `list_models` + `spawn_agent` round trip.
    """
    |> String.trim_trailing()
  end

  defp tool_section(_), do: ""

  # ---------------------------------------------------------------------------
  # Skills
  # ---------------------------------------------------------------------------

  @spec append_skills(String.t(), [String.t()], (-> [Skill.t()]) | nil) :: String.t()
  defp append_skills(prompt, [], _), do: prompt
  defp append_skills(prompt, _, nil), do: prompt

  defp append_skills(prompt, names, refresh_fn) do
    pool = refresh_fn.()
    pool_map = Map.new(pool, &{&1.name, &1})
    resolved = Enum.flat_map(names, &List.wrap(Map.get(pool_map, &1)))

    case Skill.system_prompt_section(resolved) do
      nil -> prompt
      section -> append_section(prompt, section)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @spec append_section(String.t(), String.t()) :: String.t()
  defp append_section("", section), do: section
  defp append_section(prompt, section), do: prompt <> "\n\n" <> section
end
