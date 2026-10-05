defmodule Planck.Agent.Context do
  @moduledoc """
  Context fields for a running agent.

  Holds the conversation state: working directory, system prompt, tools,
  messages, token usage, and the dissolved skill index fields.

  Skill index fields (formerly `Planck.Agent.SkillIndex`):
  - `skills_pool` — frozen list of `Skill.t()` for the system prompt
  - `skills_ranked` — skill names ordered by usage history
  - `skills_top_n` — maximum number of ranked skills shown
  - `skills_names` — skill names declared in TEAM.json
  - `skills_refresh_fn` — returns the live skill pool for tool dispatch
  - `skills_index_refresh_fn` — rebuilds `skills_pool`/`skills_ranked` after compaction
  """

  alias Planck.Agent.{Hooks, Identity, Message, Skill, Tool, TurnContext, Usage}
  alias Planck.Agent.Hooks.Persistence
  alias Planck.AI.Context, as: AIContext

  @typedoc """
  An agent's context.
  """
  @type t :: %__MODULE__{
          cwd: String.t(),
          system_prompt: String.t(),
          tools: %{String.t() => Tool.t()},
          messages: [Message.t()],
          context_tokens: non_neg_integer(),
          usage: Usage.t(),
          opts: keyword(),
          skills_pool: [Skill.t()],
          skills_ranked: [String.t()],
          skills_top_n: pos_integer(),
          skills_names: [String.t()],
          skills_refresh_fn: (-> [Skill.t()]) | nil,
          skills_index_refresh_fn: (-> {[Skill.t()], [String.t()]}) | nil
        }

  @doc false
  defstruct cwd: "",
            system_prompt: "",
            tools: %{},
            messages: [],
            context_tokens: 0,
            usage: %Usage{},
            opts: [],
            skills_pool: [],
            skills_ranked: [],
            skills_top_n: 5,
            skills_names: [],
            skills_refresh_fn: nil,
            skills_index_refresh_fn: nil

  @doc """
  Build a `Context` from agent start opts and a tool map.
  """
  @spec build(keyword()) :: t()
  def build(opts)

  def build(opts) when is_list(opts) do
    tool_list = opts[:tools] || []
    tool_map = Map.new(tool_list, &{&1.name, &1})

    %__MODULE__{
      cwd: opts[:cwd] || "",
      system_prompt: opts[:system_prompt] || "",
      tools: tool_map,
      opts: opts,
      usage: Usage.from_opts(opts),
      skills_pool: opts[:skill_pool] || [],
      skills_ranked: opts[:ranked_skill_names] || [],
      skills_top_n: opts[:top_skills] || 5,
      skills_names: opts[:skill_names] || [],
      skills_refresh_fn: opts[:skill_refresh_fn],
      skills_index_refresh_fn: opts[:skill_index_refresh_fn]
    }
  end

  @doc "Add a tool at runtime."
  @spec add_tool(t(), Tool.t()) :: t()
  def add_tool(context, tool)

  def add_tool(%__MODULE__{} = ctx, %Tool{} = tool) do
    %{ctx | tools: Map.put(ctx.tools, tool.name, tool)}
  end

  @doc "Remove a tool by name at runtime."
  @spec remove_tool(t(), String.t()) :: t()
  def remove_tool(context, name)

  def remove_tool(%__MODULE__{} = ctx, name) when is_binary(name) do
    %{ctx | tools: Map.delete(ctx.tools, name)}
  end

  @doc "Updates usage in context"
  @spec update_usage(t(), Identity.t(), Hooks.t(), non_neg_integer(), non_neg_integer()) :: t()
  def update_usage(context, identity, hooks, input, output)

  def update_usage(
        %__MODULE__{} = ctx,
        %Identity{} = identity,
        %Hooks{} = hooks,
        input,
        output
      )
      when is_integer(input) and input >= 0 and is_integer(output) and output >= 0 do
    usage = Usage.add_turn(ctx.usage, input, output, identity.model)
    ctx = %{ctx | usage: usage}
    persist_usage(ctx, identity, hooks)
    ctx
  end

  @doc "Replaces messages in the context"
  @spec replace_messages(t(), Identity.t(), Hooks.t(), [Message.t()]) :: t()
  @spec replace_messages(t(), Identity.t(), Hooks.t(), [Message.t()], keyword()) :: t()
  def replace_messages(context, identity, hooks, messages, opts \\ [])

  def replace_messages(
        %__MODULE__{} = ctx,
        %Identity{} = identity,
        %Hooks{} = hooks,
        messages,
        opts
      )
      when is_list(messages) and is_list(opts) do
    messages =
      if opts[:persist] do
        Enum.map(messages, &persist_message(identity, hooks, &1))
      else
        messages
      end

    %{ctx | messages: messages}
  end

  @doc "Appends messages to the context"
  @spec append_messages(t(), Identity.t(), Hooks.t(), [Message.t()]) :: t()
  @spec append_messages(t(), Identity.t(), Hooks.t(), [Message.t()], keyword()) :: t()
  def append_messages(context, identity, hooks, messages, opts \\ [])

  def append_messages(
        %__MODULE__{} = ctx,
        %Identity{} = identity,
        %Hooks{} = hooks,
        messages,
        opts
      )
      when is_list(messages) and is_list(opts) do
    messages =
      if opts[:persist] do
        Enum.map(messages, &persist_message(identity, hooks, &1))
      else
        messages
      end

    %{ctx | messages: ctx.messages ++ messages}
  end

  @doc "Remove unpersisted"
  @spec remove_unpersisted(t(), String.t()) :: t()
  def remove_unpersisted(context, id)

  def remove_unpersisted(%__MODULE__{} = ctx, id)
      when is_binary(id) do
    messages = Enum.reject(ctx.messages, &(&1.id == id))
    %{ctx | messages: messages}
  end

  @doc "Build the AI request context from identity, hooks, and context."
  @spec calculate_context(t(), Identity.t(), Hooks.t()) ::
          {t(), [Message.t()], AIContext.t()}
  def calculate_context(context, identity, hooks)

  def calculate_context(%__MODULE__{} = ctx, %Identity{} = identity, %Hooks{} = hooks) do
    ai_tools =
      ctx.tools
      |> Map.values()
      |> Enum.map(&Tool.to_ai_tool/1)

    system = build_system_prompt(ctx, identity, hooks)

    recent = TurnContext.messages_since_last_summary(ctx.messages)

    context =
      %AIContext{
        system: presence(system),
        messages: Message.to_ai_messages(recent),
        tools: ai_tools
      }

    context_tokens = AIContext.estimate_tokens(context)

    {%{ctx | context_tokens: context_tokens}, recent, context}
  end

  @doc "Drains control marker from the context"
  @spec drain_control_markers(t(), Identity.t(), Hooks.t()) ::
          {:clear, t()}
          | {:compact, t(), %{prompt: String.t() | nil}}
          | :none
  def drain_control_markers(context, identity, hooks)

  def drain_control_markers(%__MODULE__{} = ctx, %Identity{} = identity, %Hooks{} = hooks) do
    messages = Enum.reverse(ctx.messages)

    cond do
      Enum.any?(messages, &(&1.role == {:custom, :clear} and is_binary(&1.id))) ->
        clear_messages(ctx, identity, hooks)

      Enum.any?(messages, &(&1.role == {:custom, :compact} and is_binary(&1.id))) ->
        compact_messages(ctx)

      true ->
        :none
    end
  end

  @doc """
  Compacts the context.
  """
  @spec compact(t(), Identity.t(), Hooks.t(), keyword()) :: t()
  def compact(context, identity, hooks, opts)

  def compact(%__MODULE__{} = ctx, %Identity{} = identity, %Hooks{} = hooks, opts)
      when is_list(opts) do
    {ctx, recent, ai_context} = calculate_context(ctx, identity, hooks)

    case Hooks.Compactor.compact(identity, hooks, ai_context, recent, opts) do
      :skip ->
        ctx

      {:compact, %Message{} = summary, kept} ->
        summary = persist_message(identity, hooks, summary)

        prefix_len = length(ctx.messages) - length(recent)
        prefix = Enum.take(ctx.messages, prefix_len)

        ctx = %{ctx | messages: prefix ++ [summary | kept]}
        refresh_skills(ctx)
    end
  end

  @doc "Reload messages from the session store."
  @spec reload_from_session(t(), Identity.t(), Hooks.t()) :: t()
  def reload_from_session(context, identity, hooks)

  def reload_from_session(%__MODULE__{} = ctx, %Identity{} = identity, %Hooks{} = hooks) do
    load_session(ctx, identity, hooks, strip_orphans: true)
  end

  @doc "Load messages from the session store without stripping orphans."
  @spec load_messages(t(), Identity.t(), Hooks.t()) :: t()
  def load_messages(context, identity, hooks)

  def load_messages(%__MODULE__{} = ctx, %Identity{} = identity, %Hooks{} = hooks) do
    load_session(ctx, identity, hooks, strip_orphans: false)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec build_system_prompt(t(), Identity.t(), Hooks.t()) :: String.t()
  defp build_system_prompt(context, identity, hooks)

  defp build_system_prompt(%__MODULE__{} = ctx, %Identity{} = identity, %Hooks{} = hooks) do
    Planck.Agent.SystemPrompt.build(%{
      system_prompt: ctx.system_prompt,
      name: identity.name,
      type: identity.type,
      tools: ctx.tools,
      skill_pool: ctx.skills_pool,
      ranked_skill_names: ctx.skills_ranked,
      top_skills: ctx.skills_top_n,
      prompt_hook: hooks.prompt,
      session_id: identity.session_id,
      sidecar_node: hooks.sidecar_node
    })
  end

  @doc "Persist a message via the hooks persistence layer."
  @spec persist_message(Identity.t(), Hooks.t(), Message.t()) :: Message.t()
  def persist_message(identity, hooks, msg)

  def persist_message(%Identity{} = identity, %Hooks{} = hooks, %Message{} = msg) do
    Persistence.persist_message(
      hooks.persistence,
      identity.session_id,
      identity.id,
      msg,
      hooks.sidecar_node
    )
  end

  @doc "Persist usage via the hooks persistence layer."
  @spec persist_usage(t(), Identity.t(), Hooks.t()) :: :ok
  def persist_usage(context, identity, hooks)

  def persist_usage(%__MODULE__{} = ctx, %Identity{} = identity, %Hooks{} = hooks) do
    Persistence.persist_usage(
      hooks.persistence,
      identity.session_id,
      identity.id,
      ctx.usage,
      hooks.sidecar_node
    )
  end

  @doc "Flush unpersisted messages and reload from session."
  @spec flush_unpersisted(t(), Identity.t(), Hooks.t()) :: t()
  def flush_unpersisted(context, identity, hooks)

  def flush_unpersisted(%__MODULE__{} = ctx, %Identity{} = identity, %Hooks{} = hooks) do
    result =
      Persistence.flush_unpersisted(
        hooks.persistence,
        identity.session_id,
        identity.id,
        ctx.messages,
        hooks.sidecar_node
      )

    case result do
      :noop ->
        ctx

      :flushed ->
        reload_from_session(ctx, identity, hooks)
    end
  end

  ##############################################################################
  # Private helpers

  @spec presence(String.t()) :: String.t() | nil
  defp presence(str)
  defp presence(""), do: nil
  defp presence(str), do: str

  @spec refresh_skills(t()) :: t()
  defp refresh_skills(context)

  defp refresh_skills(%__MODULE__{skills_index_refresh_fn: nil} = ctx) do
    ctx
  end

  defp refresh_skills(%__MODULE__{skills_index_refresh_fn: fun} = ctx) do
    {pool, ranked} = fun.()
    %{ctx | skills_pool: pool, skills_ranked: ranked}
  end

  @spec load_session(t(), Identity.t(), Hooks.t(), keyword()) :: t()
  defp load_session(context, identity, hooks, opts)

  defp load_session(%__MODULE__{} = ctx, %Identity{} = identity, %Hooks{} = hooks, opts)
       when is_list(opts) do
    result =
      Persistence.load_messages(
        hooks.persistence,
        identity.session_id,
        identity.id,
        opts,
        hooks.sidecar_node
      )

    case result do
      {:ok, messages} ->
        %{ctx | messages: messages}

      :error ->
        ctx
    end
  end

  @spec clear_messages(t(), Identity.t(), Hooks.t()) :: {:clear, t()}
  defp clear_messages(context, identity, hooks)

  defp clear_messages(%__MODULE__{} = ctx, %Identity{} = identity, %Hooks{} = hooks) do
    content = "Previous conversation cleared — ignored going forward."
    msg = Message.new({:custom, :clear}, [{:text, content}])

    ctx = %{ctx | messages: [persist_message(identity, hooks, msg)]}

    {:clear, ctx}
  end

  @spec compact_messages(t()) ::
          {:compact, t(), args}
          | :none
        when args: %{:prompt => nil | String.t()}
  defp compact_messages(context)

  defp compact_messages(%__MODULE__{} = ctx) do
    ctx.messages
    |> Enum.reverse()
    |> Enum.find(&(&1.role == {:custom, :compact} and is_binary(&1.id)))
    |> case do
      %Message{} = last_compact ->
        prompt = last_compact.metadata[:prompt]
        remaining = Enum.reject(ctx.messages, &control_marker?/1)
        {:compact, %{ctx | messages: remaining}, %{prompt: prompt}}

      _ ->
        :none
    end
  end

  @spec control_marker?(Message.t()) :: boolean()
  defp control_marker?(message)

  defp control_marker?(%Message{} = message) do
    case message do
      %Message{role: {:custom, :clear}, id: id} when is_binary(id) -> true
      %Message{role: {:custom, :compact}, id: id} when is_binary(id) -> true
      _ -> false
    end
  end
end
