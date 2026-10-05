defmodule Planck.Agent do
  @moduledoc """
  OTP-based LLM agent.

  Each agent is a `GenServer` that drives the LLM loop:
  stream a response → collect tool calls → execute them concurrently →
  append results → re-stream until the model stops.

  ## Roles

  An agent's role is derived from its tool list at start time:

  - **Orchestrator** — has a tool named `"spawn_agent"` in its list. Owns a
    `team_id`; all agents sharing that `team_id` are terminated when this
    agent exits.
  - **Worker** — no `"spawn_agent"` tool. Receives tasks and reports back.

  ## Events

  Subscribers receive `{:agent_event, type, payload}` messages:

  | Event | Payload keys |
  |---|---|
  | `:turn_start` | `index` |
  | `:turn_end` | `message`, `usage` |
  | `:text_delta` | `text` |
  | `:thinking_delta` | `text` |
  | `:usage_delta` | `delta` (`input_tokens`, `output_tokens`, `cost`), `total` (`input_tokens`, `output_tokens`, `cost`), `context_tokens` |
  | `:tool_start` | `id`, `name`, `args` |
  | `:tool_end` | `id`, `name`, `result`, `error` |
  | `:worker_spawned` | — |
  | `:worker_exit` | `pid`, `reason` |
  | `:error` | `reason` |
  | `:message_cancelled` | `id` |

  ## Example

      {:ok, pid} = DynamicSupervisor.start_child(
        Planck.Agent.AgentSupervisor,
        {Planck.Agent,
          id: "agent-1",
          model: model,
          system_prompt: "You are helpful.",
          tools: [read_tool]}
      )

      Planck.Agent.subscribe(pid)
      Planck.Agent.prompt(pid, "What is in lib/app.ex?")
  """

  use GenServer

  alias Planck.Agent.{
    AIBehaviour,
    Command,
    Context,
    EExRenderer,
    Hooks,
    Identity,
    Message,
    MessageBuilder,
    Skill,
    Tool,
    Turn,
    TurnContext
  }

  alias Planck.AI.Context, as: AIContext

  @typedoc "A reference to a running agent — pid, registered name, or via-tuple."
  @type agent :: pid() | atom() | {:via, module(), term()}

  # ---------------------------------------------------------------------------
  # State
  # ---------------------------------------------------------------------------

  @typedoc """
  Internal GenServer state for an agent.

  Identity fields (grouped in `identity`):
  - `id` — unique agent identifier
  - `name` / `description` / `type` — display metadata set at start time
  - `team_id` — registry namespace shared by all agents in the same team
  - `team_name` — stable team alias (directory name); `"default"` for dynamic teams
  - `session_id` — SQLite session this agent persists messages to; `nil` for
    ephemeral agents
  - `delegator_id` — id of the orchestrator that spawned this worker; `nil` for
    orchestrators
  - `role` — `:orchestrator` (has `spawn_agent` tool) or `:worker`
  - `model` — the `Planck.AI.Model` the agent is configured to use

  Context fields:
  - `system_prompt` — prepended to every LLM context
  - `cwd` — working directory for the session; used to locate `AGENTS.md`
  - `messages` — full in-memory conversation history (`Message.t()` list)
  - `tools` — map of tool name → `Tool.t()` available to this agent
  - `skills` — frozen skill index for system prompt building and tool dispatch
  - `usage` — accumulated token counts and cost for this session
  - `context_tokens` — estimated size (system prompt + messages + tool schemas)
    of the request built for the most recently started LLM call; see
    `Planck.AI.Context.estimate_tokens/1`
  - `opts` — pass-through keyword options (e.g. `tool_timeout`)

  Turn fields:
  - `status` — `:idle`, `:streaming`, or `:executing_tools`
  - `turn_state` — monotonically increasing turn counter and checkpoint stack
  - `stream_task` / `stream_ref` — in-flight async LLM stream
  - `stream_start` — length of `messages` when the current stream began; used to
    detect messages appended *during* streaming that the LLM did not see
  - `stream_buffer` — accumulates text/thinking/tool-call deltas during streaming
  - `tool_runner` — tracks in-flight tool tasks and their accumulated results

  Hook fields (grouped in `hooks`):
  - `compactor` — resolved module atom for context compaction; `nil` uses the
    built-in LLM-based compactor
  - `persistence` — resolved module atom for conversation persistence; `nil`
    uses the built-in SQLite-backed store
  - `prompt` — resolved module atom for per-turn system prompt injection
    (prepend/append); `nil` means no injection
  - `turn_end` — resolved module atom called after every turn ends;
    `nil` means no post-turn reflection
  - `sidecar_node` — connected sidecar node; shared by all hook dispatch calls
  - `available_models` — model catalog used by `list_models` and `spawn_agent`
  """
  @type t :: %__MODULE__{
          identity: Identity.t(),
          hooks: Hooks.t(),
          context: Context.t(),
          turn: Turn.t(),
          available_models: [Planck.AI.Model.t()]
        }

  @doc false
  defstruct identity: %Identity{},
            hooks: %Hooks{},
            context: %Context{},
            turn: %Turn{},
            available_models: []

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Start an agent under a supervisor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts)

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, [])
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts)

  def child_spec(opts) when is_list(opts) do
    %{
      id: Keyword.fetch!(opts, :id),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @doc """
  Send a user message and kick off the agent loop. Returns once the agent
  status is :streaming.

  Pass `edit: id` to instead replace the text of a message with that id —
  only succeeds if it's still the last, unpersisted message queued while
  the agent was busy; fails with `{:error, :already_sent}` once it's been
  flushed to the session (the caller decides how to fall back, e.g. the
  normal rewind-based edit, once the message has a real db id).
  """
  @spec prompt(agent(), content, keyword()) ::
          :ok
          | {:error, :already_sent}
        when content: String.t() | [Planck.AI.Message.content_part()]
  def prompt(agent, content, opts \\ [])

  def prompt(agent, content, opts) do
    GenServer.call(agent, {:prompt, content, opts})
  end

  @doc """
  Dispatch a custom slash command to the agent.

  Enqueues a `{:custom, :command}` message carrying `command_meta` and the
  rendered command body. When the agent is idle, a new turn starts
  immediately; when busy, the message stacks in `state.messages` (broadcast
  as `:message_queued` with `role: :command`) and starts a turn at the next
  turn boundary.
  """
  @spec command(agent(), Command.t(), String.t() | nil) ::
          :ok
          | {:error, :already_sent}
  def command(agent, command, args)

  def command(agent, %Command{} = command, args) do
    args = Regex.split(~r/\s/, args || "", trim: true)
    rendered = EExRenderer.render(command.template, args: args)

    meta = %{command: %{name: command.name, args: args}, invoked_by: :user}

    GenServer.call(agent, {:command, meta, rendered})
  end

  @doc """
  Cancel a message still queued (unpersisted) in the agent's in-memory
  message list.

  Covers queued user messages, custom-command messages, and the
  `{:custom, :clear}` / `{:custom, :compact}` primitive markers. Returns
  `{:error, :already_sent}` if the message has already been flushed to the
  session (its id is now a db id, not the agent's string id), or
  `{:error, :not_found}` if no message with that id is in the list. No
  broadcast — the caller removes its own UI entry on `:ok`.
  """
  @spec cancel_queued(agent(), String.t() | non_neg_integer()) ::
          :ok
          | {:error, :not_found}
          | {:error, :already_sent}
  def cancel_queued(agent, id)

  def cancel_queued(agent, id) when is_binary(id) or is_integer(id) do
    GenServer.call(agent, {:cancel_queued, id})
  end

  @doc """
  Load a skill into the agent's context.

  Reads the skill's `SKILL.md`, enqueues a `{:custom, :skill}` message
  carrying the `Skill.t()` struct and the rendered content in metadata.
  If `user_text` is non-empty, it is enqueued as a `:user` message after
  the skill message. When the agent is idle a turn starts immediately;
  when busy both messages stack and run at the next turn boundary.

  User-initiated skill loading does not record usage — only the
  autonomous `load_skill` tool path records via `on_skill_use`.

  Replaces the previous `inject_tool_result` + `prompt` pair used for
  slash-command skill loading. The LLM sees the skill content as a
  `:user` message (via `Message.to_ai_messages/1`).
  """
  @spec load_skill(agent(), Planck.Agent.Skill.t(), String.t() | nil) :: :ok
  def load_skill(agent, skill, user_text)

  def load_skill(agent, %Skill{} = skill, nil) do
    GenServer.call(agent, {:load_skill, skill, nil})
  end

  def load_skill(agent, %Skill{} = skill, user_text)
      when is_binary(user_text) do
    if String.trim(user_text) == "" do
      load_skill(agent, skill, nil)
    else
      GenServer.call(agent, {:load_skill, skill, user_text})
    end
  end

  @doc """
  Trigger the agent to run an LLM turn without adding a new user message.

  Used after session resume when a recovery context message is already present
  in the agent's history and just needs to be acted upon.
  """
  @spec nudge(agent()) :: :ok
  def nudge(agent)

  def nudge(agent) do
    GenServer.cast(agent, :nudge)
  end

  @doc """
  Cancel in-flight streaming and tool execution. Blocks until the agent has
  returned to `:idle` (or started a follow-up turn for any queued messages).
  """
  @spec abort(agent()) :: :ok
  def abort(agent)

  def abort(agent) do
    GenServer.call(agent, :abort)
  end

  @doc """
  Truncate the session to strictly before `message_id`, then reload the
  agent's in-memory message history from the DB (the source of truth).
  `turn_checkpoints` is rebuilt from the reloaded message list.

  Only meaningful for agents with a `session_id`. A no-op for ephemeral agents.
  """
  @spec rewind_to_message(agent(), pos_integer() | String.t()) :: :ok
  def rewind_to_message(agent, message_id)

  def rewind_to_message(agent, message_id)
      when (is_integer(message_id) and message_id > 0) or is_binary(message_id) do
    GenServer.cast(agent, {:rewind_to_message, message_id})
  end

  @doc """
  Insert a summary checkpoint into the agent's conversation.

  Builds a `{:custom, :summary}` message with `summary_text`, persists it,
  and appends it to in-memory history. The agent's next LLM call will only
  see the checkpoint and any messages after it via `messages_since_last_summary`.

  Works regardless of the agent's current status.
  """
  @spec checkpoint(agent(), String.t()) :: :ok
  def checkpoint(agent, summary_text)

  def checkpoint(agent, summary_text)
      when is_binary(summary_text) do
    GenServer.call(agent, {:checkpoint, summary_text})
  end

  @doc """
  Delete all messages in the session and reset the agent's in-memory history.

  The session process itself stays alive and its metadata is preserved. No
  LLM call is made. If the agent is busy, the clear is queued and executed
  at the next turn boundary, before any queued user messages.
  """
  @spec clear(agent()) :: :ok
  def clear(agent)

  def clear(agent) do
    GenServer.call(agent, :clear)
  end

  @doc """
  Force a compaction pass on demand, bypassing the compactor's own trigger
  heuristic.

  `args` is a map that may contain `:prompt` — a user-supplied string (from
  `/compact [prompt]`) that can steer the summarization. When the agent is
  idle, compaction runs immediately. When busy, it is queued and runs at
  the next turn boundary, before any queued user message starts a new turn.

  Returns `:ok` immediately — the actual compaction runs in a
  `handle_continue` so the caller's `GenServer.call` doesn't timeout while
  the delegate agent summarises (which can take tens of seconds). Progress
  is reported via `:compacting` / `:compacted` PubSub events.
  """
  @spec compact(agent(), args) :: :ok
        when args: %{:prompt => prompt},
             prompt: String.t() | nil
  def compact(agent, args \\ %{prompt: nil})

  def compact(agent, %{prompt: _} = args) do
    GenServer.call(agent, {:compact, args})
  end

  @doc "Stop the agent. Cancels any in-flight work and removes it from the supervisor."
  @spec stop(agent()) :: :ok
  def stop(agent)

  def stop(agent) do
    GenServer.stop(agent)
  end

  @doc "Synchronous state snapshot."
  @spec get_state(agent()) :: map()
  def get_state(agent)

  def get_state(agent) do
    GenServer.call(agent, :get_state)
  end

  @doc "Lightweight summary: id, name, description, type, role, status, turn_index, usage."
  @spec get_info(agent()) :: map()
  def get_info(agent)

  def get_info(agent) do
    GenServer.call(agent, :get_info)
  end

  @doc """
  Estimate the number of tokens currently in the agent's context window —
  system prompt, tool schemas, and conversation, not just the conversation.
  Reflects the request built for the most recently started LLM call (see
  `state.context_tokens`'s own doc), not a fresh recomputation.
  """
  @spec estimate_tokens(agent()) :: non_neg_integer()
  def estimate_tokens(agent)

  def estimate_tokens(agent) do
    GenServer.call(agent, :estimate_tokens)
  end

  @doc "Replace the model used for subsequent LLM turns without interrupting the current state."
  @spec change_model(agent(), Planck.AI.Model.t()) :: :ok
  def change_model(agent, model)

  def change_model(agent, %Planck.AI.Model{} = model) do
    GenServer.call(agent, {:change_model, model})
  end

  @doc """
  Subscribe the calling process to `{:agent_event, type, payload}` messages.

  Accepts either an agent id string or a pid/name. The pid form resolves the id
  via `get_info/1` — prefer passing the id directly when available.
  """
  @spec subscribe(String.t() | agent()) :: :ok | {:error, term()}
  def subscribe(agent_id)

  def subscribe(agent_id) when is_binary(agent_id) do
    Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "agent:#{agent_id}")
  end

  def subscribe(agent) do
    %{id: agent_id} = get_info(agent)
    subscribe(agent_id)
  end

  @doc "Add a tool at runtime."
  @spec add_tool(agent(), Tool.t()) :: :ok
  def add_tool(agent, tool)

  def add_tool(agent, %Tool{} = tool) do
    GenServer.cast(agent, {:add_tool, tool})
  end

  @doc "Remove a tool by name at runtime."
  @spec remove_tool(agent(), String.t()) :: :ok
  def remove_tool(agent, name)

  def remove_tool(agent, name) when is_binary(name) do
    GenServer.cast(agent, {:remove_tool, name})
  end

  @doc """
  Resolve an agent id to its pid, anywhere in the connected distributed
  Erlang cluster — not just the calling node's own `Registry`.

  Checks the calling node's own `Registry` first (fast, no RPC — and the
  only thing that can find it when the caller and the agent share a node,
  which every call site originally assumed). Falls back to asking every
  node in `Node.list/0`, in order, stopping at the first hit.

  The fallback matters for code that runs on a **different** node than
  `planck_agent`'s own processes — concretely, sidecar tools and hooks
  (`Sidecar.Tools.Beads`, `Sidecar.Tools.UpdateMemory`,
  `Sidecar.SkillReflector.Runner`), which execute on the sidecar node while
  every real `Planck.Agent` GenServer runs on the connected
  `planck_headless` node. A local-only lookup there always returned
  `{:error, :not_found}` regardless of whether the agent was actually
  running — `Registry` is per-node and does not replicate across a
  distributed Erlang connection, confirmed by this failing in exactly that
  shape in real (non-test) use. Every one of those call sites' own unit
  tests passed anyway, because a unit test starts a real `Planck.Agent` in
  the *same* test process/node — the one topology where the gap was never
  going to show up.

  Headless-side callers (inter-agent tools, `planck_cli`'s session/event
  code) always target a same-node agent, so the fallback is a no-op there
  in the success case; on a genuine miss it costs one extra, fast RPC round
  trip to the connected sidecar (which never has a matching entry) before
  returning `{:error, :not_found}` — a small, bounded cost worth paying to
  have one function that's simply always correct, rather than a second,
  easy-to-forget name for callers that happen to run elsewhere.
  """
  @spec whereis(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def whereis(id)

  def whereis(id) when is_binary(id) do
    with {:error, :not_found} <- locate_local(id) do
      locate_remote(id, Node.list())
    end
  end

  # ---------------------------------------------------------------------------
  # Agent resolution functions
  # ---------------------------------------------------------------------------

  @spec locate_local(String.t()) :: {:ok, pid()} | {:error, :not_found}
  defp locate_local(id)

  defp locate_local(id) when is_binary(id) do
    case Registry.lookup(Planck.Agent.Registry, {:agent, id}) do
      [{pid, _}] -> {:ok, pid}
      _ -> {:error, :not_found}
    end
  end

  @spec locate_remote(String.t(), [node()]) :: {:ok, pid()} | {:error, :not_found}
  defp locate_remote(id, nodes)

  defp locate_remote(_id, []) do
    {:error, :not_found}
  end

  defp locate_remote(id, [node | rest]) when is_binary(id) do
    case :rpc.call(node, __MODULE__, :locate_local, [id], 5_000) do
      {:ok, pid} -> {:ok, pid}
      _ -> locate_remote(id, rest)
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %__MODULE__{
      identity: Identity.build(opts),
      hooks: Hooks.build(opts),
      context: Context.build(opts),
      turn: Turn.new(),
      available_models: Keyword.get(opts, :available_models, [])
    }

    register_agent(state)
    link_to_orchestrator(state)

    # Orchestrators trap exits so they survive individual worker crashes.
    if state.identity.role == :orchestrator,
      do: Process.flag(:trap_exit, true)

    # Notify session subscribers so UIs can refresh the agent list.
    if state.identity.delegator_id,
      do: broadcast(state, :worker_spawned, %{})

    # Load existing session history (if any) and strip orphaned tool-call turns
    # left by a previous crash. Deferred to a continue so the process is
    # registered before any synchronous Session calls run.
    if state.identity.session_id do
      {:ok, state, {:continue, :load_session_history}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_call(event, from, state)

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:get_info, _from, state) do
    info = %{
      id: state.identity.id,
      name: state.identity.name,
      description: state.identity.description,
      type: state.identity.type,
      role: state.identity.role,
      status: state.turn.status,
      turn_index: state.turn.index,
      usage: %{
        input_tokens: state.context.usage.input_tokens,
        output_tokens: state.context.usage.output_tokens
      },
      cost: state.context.usage.cost
    }

    {:reply, info, state}
  end

  def handle_call({:change_model, model}, _from, state) do
    identity = Identity.set_model(state.identity, model)
    state = %{state | identity: identity}
    {:reply, :ok, state}
  end

  def handle_call(:estimate_tokens, _from, state) do
    {:reply, state.context.context_tokens, state}
  end

  def handle_call({:prompt, content, opts}, _from, state) when is_list(opts) do
    case Keyword.fetch(opts, :edit) do
      {:ok, id} -> do_edit_queued(id, content, state)
      :error -> do_prompt_or_queue(content, state)
    end
  end

  def handle_call({:command, command_meta, content}, _from, state) do
    do_prompt_or_queue_command(content, command_meta, state)
  end

  def handle_call({:cancel_queued, id}, _from, state) do
    do_cancel_queued(id, state)
  end

  def handle_call({:load_skill, skill, user_text}, _from, state) do
    do_load_skill(skill, user_text, state)
  end

  def handle_call(:abort, _from, state) do
    do_abort(state)
  end

  def handle_call({:checkpoint, summary_text}, _from, state) do
    do_checkpoint(state, summary_text)
  end

  def handle_call(:clear, _from, state) do
    do_clear(state)
  end

  def handle_call({:compact, args}, _from, state) do
    do_compact(state, args)
  end

  @impl true
  def handle_cast(event, state)

  def handle_cast(:nudge, state) do
    if state.turn.status == :idle do
      {:noreply, state, {:continue, {:run_llm, :new_turn}}}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:rewind_to_message, message_id}, state) do
    if state.identity.session_id do
      {:noreply, reload_messages_from_session(state, message_id)}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:add_tool, tool}, state) do
    context = Context.add_tool(state.context, tool)
    {:noreply, %{state | context: context}}
  end

  def handle_cast({:remove_tool, name}, state) do
    context = Context.remove_tool(state.context, name)
    {:noreply, %{state | context: context}}
  end

  @impl true
  def handle_continue(message, state)

  def handle_continue(:load_session_history, state) do
    # Load history without stripping orphans — resume_session may not have
    # injected its recovery message yet, so stripping here would race with it.
    # Orphan stripping happens later in reload_messages_from_session (called from
    # flush_unpersisted_messages) once the session state is fully settled.
    {:noreply, load_messages_from_session(state)}
  end

  def handle_continue(:run_llm, state) do
    {:noreply, do_run_llm(state, :continuation)}
  end

  def handle_continue({:run_llm, :new_turn}, state) do
    broadcast(state, :turn_start, %{index: state.turn.index})
    {:noreply, do_run_llm(state, :new_turn)}
  end

  def handle_continue({:execute_tools, calls}, state) do
    {:noreply, start_tool_tasks(calls, state)}
  end

  def handle_continue({:compact, args}, state) do
    state
    |> apply_compact(args: args, force: true)
    |> maybe_turn_start()
  end

  @impl true
  def handle_info(event, state)

  def handle_info({:stream_event, ref, event}, %{turn: %{stream_ref: ref}} = state) do
    {:noreply, process_event(state, event)}
  end

  def handle_info({:stream_event, _stale, _event}, state) do
    {:noreply, state}
  end

  def handle_info({:stream_done, ref}, %{turn: %{stream_ref: ref}} = state) do
    do_stream_done(state)
  end

  def handle_info({:stream_done, _stale}, state) do
    {:noreply, state}
  end

  def handle_info({:tool_done, call_id, name, result}, state) do
    do_tool_done(state, call_id, name, result)
  end

  def handle_info({:agent_response, response, sender}, state) do
    do_agent_response(response, sender, state)
  end

  def handle_info({:EXIT, pid, reason}, state) do
    broadcast(state, :worker_exit, %{pid: pid, reason: reason})
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Turn.cancel_stream(state.turn)
    Turn.cancel_all_tools(state.turn)
  end

  # ---------------------------------------------------------------------------
  # Prompt normal messages
  # ---------------------------------------------------------------------------

  @spec do_prompt_or_queue(content, t()) ::
          {:reply, :ok, t()}
          | {:reply, :ok, t(), {:continue, {:run_llm, :new_turn}}}
        when content: String.t() | [Planck.AI.Message.content_part()]
  defp do_prompt_or_queue(content, state)

  defp do_prompt_or_queue(content, %__MODULE__{} = state)
       when is_binary(content) or is_list(content) do
    parts = MessageBuilder.normalize_content(content)
    message = Message.new(:user, parts)

    if state.turn.status == :idle do
      state = do_prompt(state, message)
      {:reply, :ok, state, {:continue, {:run_llm, :new_turn}}}
    else
      state = do_queue(state, message, content: message.content)
      {:reply, :ok, state}
    end
  end

  @spec do_prompt(t(), Message.t() | [Message.t()]) :: t()
  defp do_prompt(state, message_or_messages)

  defp do_prompt(%__MODULE__{} = state, %Message{} = message) do
    do_prompt(state, [message])
  end

  defp do_prompt(%__MODULE__{} = state, [_ | _] = messages)
       when is_list(messages) do
    state
    |> append_messages(messages, persist: true)
    |> push_checkpoint()
  end

  @spec do_queue(t(), Message.t() | [Message.t()], keyword()) :: t()
  defp do_queue(state, message_or_messages, metadata)

  defp do_queue(%__MODULE__{} = state, %Message{} = message, metadata) do
    do_queue(state, [message], metadata)
  end

  defp do_queue(%__MODULE__{} = state, [message | _] = messages, metadata)
       when is_list(messages)
       when is_list(metadata) do
    state = append_messages(state, messages)
    message_queued(state, message, metadata)
    state
  end

  # ---------------------------------------------------------------------------
  # Prompt commands
  # ---------------------------------------------------------------------------

  @spec do_prompt_or_queue_command(content, map(), t()) ::
          {:reply, :ok, t()}
          | {:reply, :ok, t(), {:continue, {:run_llm, :new_turn}}}
        when content: String.t() | [Planck.AI.Message.content_part()]
  defp do_prompt_or_queue_command(content, command_meta, state)

  defp do_prompt_or_queue_command(content, command_meta, %__MODULE__{} = state) do
    parts = MessageBuilder.normalize_content(content)
    message = Message.new({:custom, :command}, parts, command_meta)

    if state.turn.status == :idle do
      state = do_prompt(state, message)
      {:reply, :ok, state, {:continue, {:run_llm, :new_turn}}}
    else
      state =
        do_queue(state, message,
          content: message.content,
          role: :command,
          command_meta: message.metadata
        )

      {:reply, :ok, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Load skills into context
  # ---------------------------------------------------------------------------

  @spec do_load_skill(Skill.t(), nil | String.t(), t()) ::
          {:reply, :ok, t()}
          | {:reply, :ok, t(), {:continue, {:run_llm, :new_turn}}}
  defp do_load_skill(skill, user_text, state)

  defp do_load_skill(skill, user_text, state) do
    case File.read(skill.skill_file) do
      {:ok, content} ->
        add_skill(state, skill, content, user_text)

      {:error, _reason} when is_nil(user_text) ->
        {:reply, :ok, state}

      {:error, _reason} ->
        do_prompt_or_queue(user_text, state)
    end
  end

  @spec add_skill(t(), Skill.t(), String.t(), String.t() | nil) ::
          {:reply, :ok, t()}
          | {:reply, :ok, t(), {:continue, {:run_llm, :new_turn}}}
  defp add_skill(state, skill, content, user_text)

  defp add_skill(%__MODULE__{} = state, %Skill{} = skill, content, user_text)
       when is_binary(content) do
    call_id = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    tool_call_message =
      Message.new(
        :assistant,
        [{:tool_call, call_id, "load_skill", %{"name" => skill.name}}],
        %{invoked_by: :user}
      )

    content = "Skill directory: #{skill.path}\n\n" <> content

    tool_result_message =
      Message.new(
        :tool_result,
        [{:tool_result, call_id, content}]
      )

    messages =
      if is_binary(user_text) do
        user_parts = MessageBuilder.normalize_content(user_text)
        user_message = Message.new(:user, user_parts)

        [tool_call_message, tool_result_message, user_message]
      else
        [tool_call_message, tool_result_message]
      end

    if state.turn.status == :idle do
      state = do_prompt(state, messages)
      {:reply, :ok, state, {:continue, {:run_llm, :new_turn}}}
    else
      state =
        do_queue(state, messages,
          role: :skill,
          skill: %{name: skill.name},
          user_text: user_text
        )

      {:reply, :ok, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Edit queued messages
  # ---------------------------------------------------------------------------

  @spec do_edit_queued(String.t(), String.t() | [Planck.AI.Message.content_part()], t()) ::
          {:reply, :ok | {:error, :already_sent}, t()}
  defp do_edit_queued(id, content, state) do
    case List.last(state.context.messages) do
      %Message{id: ^id, role: :user} = msg ->
        parts = MessageBuilder.normalize_content(content)
        updated = %{msg | content: parts}

        messages = List.replace_at(state.context.messages, -1, updated)

        state = replace_messages(state, messages)
        message_queued(state, updated, content: parts)

        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :already_sent}, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Clear/Compact context.
  # ---------------------------------------------------------------------------

  @spec do_clear(t()) :: {:reply, :ok, t()}
  defp do_clear(state)

  defp do_clear(%__MODULE__{} = state) do
    idle? = state.turn.status == :idle

    message =
      Message.new(
        {:custom, :clear},
        [{:text, "Previous conversation cleared — ignored going forward."}]
      )

    state = replace_messages(state, [message], persist: idle?)

    if idle? do
      state = %{state | turn: Turn.new()}
      broadcast(state, :cleared, %{})
      {:reply, :ok, state}
    else
      message_queued(state, message, role: :clear)
      {:reply, :ok, state}
    end
  end

  @spec do_compact(t(), args) ::
          {:reply, :ok, t(), {:continue, {:compact, args}}}
          | {:reply, :ok, t()}
        when args: %{:prompt => prompt},
             prompt: String.t() | nil
  defp do_compact(state, args)

  defp do_compact(%__MODULE__{} = state, %{prompt: _} = args) do
    if state.turn.status == :idle do
      {:reply, :ok, state, {:continue, {:compact, args}}}
    else
      message = Message.new({:custom, :compact}, [], args)
      state = append_messages(state, [message])

      message_queued(state, message,
        role: :compact,
        args: args
      )

      {:reply, :ok, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Main loop
  # ---------------------------------------------------------------------------

  @spec do_run_llm(t(), :new_turn | :continuation) :: t()
  defp do_run_llm(state, turn_type)

  defp do_run_llm(%__MODULE__{} = state, turn_type)
       when turn_type in [:new_turn, :continuation] do
    state =
      state
      |> apply_compact()
      |> flush_unpersisted_messages()

    {context, _messages, ai_context} =
      Context.calculate_context(
        state.context,
        state.identity,
        state.hooks
      )

    state = %{state | context: context}
    ref = make_ref()
    parent = self()

    {:ok, pid} =
      Task.Supervisor.start_child(Planck.Agent.TaskSupervisor, fn ->
        stream(state, parent, ref, ai_context)
      end)

    turn =
      case turn_type do
        :new_turn ->
          Turn.start_turn(state.turn, pid, ref, state.context.messages)

        :continuation ->
          Turn.continue_turn(state.turn, pid, ref)
      end

    %{state | turn: turn}
  end

  @spec start_tool_tasks([map()], t()) :: t()
  defp start_tool_tasks(tool_calls, state) do
    parent = self()

    Enum.reduce(tool_calls, state, fn tool_call, state ->
      start_tool_task(parent, tool_call, state)
    end)
  end

  @spec start_tool_task(pid(), tool_call, t()) :: t()
        when tool_call: %{:id => String.t(), :name => String.t(), args: map()}
  defp start_tool_task(parent, tool_call, state)

  defp start_tool_task(parent, tool_call, %__MODULE__{} = state)
       when is_pid(parent) and is_map(tool_call) do
    {turn, tool_call_fn} =
      Turn.prepare_call(
        state.turn,
        state.context.tools,
        state.identity.id,
        tool_call
      )

    {:ok, pid} =
      Task.Supervisor.start_child(Planck.Agent.TaskSupervisor, fn ->
        result = tool_call_fn.()
        send(parent, {:tool_done, tool_call.id, tool_call.name, result})
      end)

    broadcast(state, :tool_start, tool_call)

    turn = Turn.register_call(turn, tool_call, pid)

    %{state | turn: turn}
  end

  @spec maybe_finish_tool_executions(t()) ::
          {:noreply, t()}
          | {:noreply, t(), {:continue, :run_llm}}
  defp maybe_finish_tool_executions(state)

  defp maybe_finish_tool_executions(%__MODULE__{} = state) do
    if Turn.tool_done?(state.turn) do
      finish_tool_execution(state)
    else
      {:noreply, state}
    end
  end

  @spec finish_tool_execution(t()) ::
          {:noreply, t(), {:continue, :run_llm}}
  defp finish_tool_execution(state)

  defp finish_tool_execution(%__MODULE__{} = state) do
    results = Enum.reverse(state.turn.results)

    tool_result_message = MessageBuilder.build_tool_result(results)

    ui_messages =
      Enum.reduce(results, [], fn
        {id, {:ok, _text, %{ui: content}}}, acc ->
          metadata = %{tool_call_id: id, ui: content}
          message = Message.new({:custom, :ui}, [], metadata)
          [message | acc]

        {_id, _result}, acc ->
          acc
      end)

    messages = [tool_result_message | ui_messages]

    state = append_messages(state, messages, persist: true)

    {:noreply, state, {:continue, :run_llm}}
  end

  @spec do_stream_done(t()) ::
          {:noreply, t()}
          | {:noreply, t(), {:continue, {:execute_tools, [map()]}}}
  defp do_stream_done(state)

  defp do_stream_done(%__MODULE__{} = state) do
    pending = state.turn.buffer_calls

    assistant_message = MessageBuilder.build_assistant(state.turn)
    state = append_messages(state, [assistant_message], persist: true)
    state = %{state | turn: Turn.reset_streaming(state.turn)}

    case pending do
      [] ->
        turn_messages = turn_messages(state)

        broadcast(state, :turn_end, %{
          message: assistant_message,
          usage: state.context.usage,
          turn_messages: turn_messages
        })

        state
        |> fire_turn_end_hook(turn_messages)
        |> maybe_turn_start()

      [_ | _] = calls ->
        {:noreply, state, {:continue, {:execute_tools, calls}}}
    end
  end

  @spec do_agent_response(String.t(), term(), t()) ::
          {:noreply, t()}
          | {:noreply, t(), {:continue, {:run_llm, :new_turn}}}
  defp do_agent_response(response, sender, state) do
    metadata =
      case sender do
        %{id: id, name: name} -> %{sender_id: id, sender_name: name}
        _ -> %{}
      end

    msg = Message.new({:custom, :agent_response}, [{:text, response}], metadata)
    msg = persist_message(state, msg)
    new_state = %{state | context: %{state.context | messages: state.context.messages ++ [msg]}}

    if state.turn.status == :idle do
      {:noreply, %{new_state | turn: %{new_state.turn | status: :streaming}},
       {:continue, {:run_llm, :new_turn}}}
    else
      {:noreply, new_state}
    end
  end

  # ---------------------------------------------------------------------------
  # Streaming helpers
  # ---------------------------------------------------------------------------

  @spec stream(t(), pid(), reference(), AIContext.t()) :: :ok
  defp stream(state, parent, reference, ai_context)

  defp stream(%__MODULE__{} = state, parent, reference, %AIContext{} = ai_context)
       when is_pid(parent) and is_reference(reference) do
    state.identity.model
    |> AIBehaviour.client().stream(ai_context, state.context.opts)
    |> Enum.each(fn event ->
      send(parent, {:stream_event, reference, event})
    end)
  rescue
    e ->
      error = {:error, Exception.message(e)}
      send(parent, {:stream_event, reference, error})
  catch
    kind, reason ->
      error = {:error, "#{kind}: #{inspect(reason)}"}
      send(parent, {:stream_event, reference, error})
  after
    send(parent, {:stream_done, reference})
  end

  @spec process_event(t(), Planck.AI.Stream.t()) :: t()
  defp process_event(state, event)

  defp process_event(%__MODULE__{} = state, {:text_delta, text}) do
    broadcast(state, :text_delta, %{text: text})
    %{state | turn: Turn.append_text(state.turn, text)}
  end

  defp process_event(%__MODULE__{} = state, {:thinking_delta, text}) do
    broadcast(state, :thinking_delta, %{text: text})
    %{state | turn: Turn.append_thinking(state.turn, text)}
  end

  defp process_event(%__MODULE__{} = state, {:tool_call_complete, call}) do
    %{state | turn: Turn.append_call(state.turn, call)}
  end

  defp process_event(%__MODULE__{} = state, {:error, reason}) do
    broadcast(state, :error, %{reason: reason})
    %{state | turn: Turn.reset_streaming(state.turn)}
  end

  defp process_event(
         %__MODULE__{} = state,
         {:done, %{usage: %{input_tokens: input, output_tokens: output}}}
       )
       when is_integer(input) and input >= 0 and is_integer(output) and output >= 0 do
    old_cost = state.context.usage.cost

    context =
      Context.update_usage(
        state.context,
        state.identity,
        state.hooks,
        input,
        output
      )

    state = %{state | context: context}

    turn_cost = state.context.usage.cost - old_cost

    broadcast(state, :usage_delta, %{
      delta: %{
        input_tokens: input,
        output_tokens: output,
        cost: turn_cost
      },
      total: %{
        input_tokens: state.context.usage.input_tokens,
        output_tokens: state.context.usage.output_tokens,
        cost: state.context.usage.cost
      },
      context_tokens: state.context.context_tokens
    })

    state
  end

  defp process_event(%__MODULE__{} = state, _other) do
    state
  end

  @spec do_tool_done(t(), String.t(), String.t(), term()) ::
          {:noreply, t()}
          | {:noreply, t(), {:continue, :run_llm}}
  defp do_tool_done(state, call_id, name, result)

  defp do_tool_done(%__MODULE__{} = state, call_id, name, result)
       when is_binary(call_id) and is_binary(name) do
    case Turn.mark_tool_done(state.turn, call_id, result) do
      :not_running ->
        {:noreply, state}

      {:ok, turn} ->
        state = %{state | turn: turn}

        error? = match?({:error, _}, result)
        info = %{id: call_id, name: name, result: result, error: error?}
        broadcast(state, :tool_end, info)

        maybe_finish_tool_executions(state)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec register_agent(t()) :: :ok
  defp register_agent(state)

  defp register_agent(%__MODULE__{
         identity: %Identity{
           id: id,
           type: type,
           name: name,
           team_id: team_id,
           description: description
         }
       }) do
    Registry.register(Planck.Agent.Registry, {:agent, id}, nil)

    if team_id do
      Registry.register(Planck.Agent.Registry, {team_id, :member}, %{
        id: id,
        type: type,
        name: name,
        description: description
      })

      if type do
        Registry.register(Planck.Agent.Registry, {team_id, type}, id)
      end

      if name do
        Registry.register(Planck.Agent.Registry, {team_id, name}, id)
      end
    end

    :ok
  end

  @spec link_to_orchestrator(t()) :: :ok
  defp link_to_orchestrator(state)

  defp link_to_orchestrator(%__MODULE__{identity: %Identity{delegator_id: nil}}) do
    :ok
  end

  defp link_to_orchestrator(%__MODULE__{identity: %Identity{delegator_id: id}}) do
    case whereis(id) do
      {:ok, pid} -> Process.link(pid)
      _ -> :ok
    end
  end

  @spec broadcast(t(), atom(), map()) :: :ok
  defp broadcast(state, type, payload)

  defp broadcast(%__MODULE__{} = state, type, payload)
       when is_atom(type) and is_map(payload) do
    id = state.identity.id
    session_id = state.identity.session_id
    agent_name = state.identity.name
    team_name = state.identity.team_name

    event = {:agent_event, type, payload}
    Phoenix.PubSub.broadcast(Planck.Agent.PubSub, "agent:#{id}", event)

    if session_id do
      session_event = {:agent_event, type, Map.put(payload, :agent_id, id)}
      Phoenix.PubSub.broadcast(Planck.Agent.PubSub, "session:#{session_id}", session_event)
    end

    if is_binary(session_id) and type in [:turn_end, :compacted, :cleared] do
      global_payload =
        payload
        |> Map.put(:agent_id, id)
        |> Map.put(:agent_name, agent_name)
        |> Map.put(:team_name, team_name)
        |> Map.put(:session_id, session_id)

      Phoenix.PubSub.broadcast(
        Planck.Agent.PubSub,
        "planck:sessions",
        {:agent_event, type, global_payload}
      )
    end
  end

  @spec flush_unpersisted_messages(t()) :: t()
  defp flush_unpersisted_messages(state)

  defp flush_unpersisted_messages(%__MODULE__{} = state) do
    context = Context.flush_unpersisted(state.context, state.identity, state.hooks)

    if context == state.context do
      state
    else
      turn = Turn.rebuild_checkpoints(state.turn, context.messages)
      state = %{state | context: context, turn: turn}
      broadcast(state, :messages_flushed, %{})
      state
    end
  end

  @spec reload_messages_from_session(t(), non_neg_integer()) :: t()
  defp reload_messages_from_session(state, message_id)

  defp reload_messages_from_session(%__MODULE__{} = state, message_id)
       when is_integer(message_id) and message_id >= 0 do
    Hooks.Persistence.truncate_after(
      state.hooks.persistence,
      state.identity.session_id,
      message_id,
      state.hooks.sidecar_node
    )

    context =
      Context.reload_from_session(
        state.context,
        state.identity,
        state.hooks
      )

    turn = Turn.rebuild_checkpoints(state.turn, context.messages)

    %{state | context: context, turn: turn}
  end

  @spec load_messages_from_session(t()) :: t()
  defp load_messages_from_session(state)

  defp load_messages_from_session(%__MODULE__{} = state) do
    context =
      Context.load_messages(
        state.context,
        state.identity,
        state.hooks
      )

    turn =
      Turn.rebuild_checkpoints(
        state.turn,
        context.messages
      )

    %{state | context: context, turn: turn}
  end

  @spec replace_messages(t(), [Message.t()]) :: t()
  @spec replace_messages(t(), [Message.t()], keyword()) :: t()
  defp replace_messages(state, messages, opts \\ [])

  defp replace_messages(state, messages, opts) do
    context =
      Context.replace_messages(
        state.context,
        state.identity,
        state.hooks,
        messages,
        opts
      )

    %{state | context: context}
  end

  @spec append_messages(t(), [Message.t()]) :: t()
  @spec append_messages(t(), [Message.t()], keyword()) :: t()
  defp append_messages(state, messages, opts \\ [])

  defp append_messages(state, messages, opts) do
    context =
      Context.append_messages(
        state.context,
        state.identity,
        state.hooks,
        messages,
        opts
      )

    %{state | context: context}
  end

  @spec push_checkpoint(t()) :: t()
  defp push_checkpoint(state)

  defp push_checkpoint(%__MODULE__{} = state) do
    turn = Turn.push_checkpoint(state.turn, state.context.messages)
    %{state | turn: turn}
  end

  @spec message_queued(t(), Message.t(), keyword()) :: :ok
  defp message_queued(state, message, info)

  defp message_queued(state, message, info) do
    info =
      info
      |> Keyword.put(:id, message.id)
      |> Keyword.put_new(:content, [])
      |> Map.new()

    broadcast(state, :message_queued, info)
  end

  @spec persist_message(t(), Message.t()) :: Message.t()
  defp persist_message(state, msg) do
    Context.persist_message(state.identity, state.hooks, msg)
  end

  @spec apply_compact(t()) :: t()
  @spec apply_compact(t(), keyword()) :: t()
  defp apply_compact(state, opts \\ [])

  defp apply_compact(%__MODULE__{} = state, opts)
       when is_list(opts) do
    opts =
      opts
      |> Keyword.put(:on_compacting, fn -> broadcast(state, :compacting, %{}) end)
      |> Keyword.put(:on_compacted, fn -> broadcast(state, :compacted, %{}) end)
      |> Keyword.put_new(:args, %{prompt: nil})

    context = Context.compact(state.context, state.identity, state.hooks, opts)

    %{state | context: context}
  end

  @spec maybe_turn_start(t()) ::
          {:noreply, t()}
          | {:noreply, t(), {:continue, term()}}
  defp maybe_turn_start(state) do
    with {:none, state} <- drain_control_markers(state),
         {:ok, state} <- start_queued_turn(state) do
      {:noreply, state}
    else
      {:clear, cleared} ->
        {:noreply, cleared}

      {:compact, state, args} ->
        {:noreply, state, {:continue, {:compact, args}}}

      {:ok, state, continue} ->
        {:noreply, state, continue}
    end
  end

  @spec start_queued_turn(t()) ::
          {:ok, t()}
          | {:ok, t(), {:continue, {:run_llm, :new_turn}}}
  defp start_queued_turn(state) do
    if TurnContext.has_pending_input?(state.context.messages, state.turn.stream_start) do
      {:ok, state, {:continue, {:run_llm, :new_turn}}}
    else
      {:ok, state}
    end
  end

  @spec drain_control_markers(t()) ::
          {:clear, t()}
          | {:compact, t(), %{:prompt => String.t() | nil}}
          | {:none, t()}
  defp drain_control_markers(state)

  defp drain_control_markers(%__MODULE__{} = state) do
    case Context.drain_control_markers(state.context, state.identity, state.hooks) do
      {:clear, context} ->
        cleared = %{state | context: context, turn: Turn.new()}
        broadcast(cleared, :cleared, %{})
        {:clear, cleared}

      {:compact, context, args} ->
        to_compact = %{state | context: context}
        {:compact, to_compact, args}

      :none ->
        {:none, state}
    end
  end

  @spec do_abort(t()) ::
          {:reply, :ok, t()}
          | {:reply, :ok, t(), {:continue, term()}}
  defp do_abort(state) do
    Turn.cancel_stream(state.turn)
    Turn.cancel_all_tools(state.turn)
    turn = Turn.reset_streaming(state.turn)
    state = %{state | turn: turn}

    with {:none, state} <- drain_control_markers(state),
         {:ok, state} <- start_queued_turn(state) do
      {:reply, :ok, state}
    else
      {:clear, cleared} ->
        {:reply, :ok, cleared}

      {:compact, state, args} ->
        {:reply, :ok, state, {:continue, {:compact, args}}}

      {:ok, state, continue} ->
        {:reply, :ok, state, continue}
    end
  end

  @spec do_checkpoint(t(), String.t()) :: {:reply, :ok, t()}
  defp do_checkpoint(state, summary_text)

  defp do_checkpoint(%__MODULE__{} = state, summary_text)
       when is_binary(summary_text) do
    message = Message.new({:custom, :summary}, [{:text, summary_text}])
    state = append_messages(state, [message], persist: true)
    {:reply, :ok, state}
  end

  @spec do_cancel_queued(String.t() | non_neg_integer(), t()) ::
          {:reply, :ok, t()}
          | {:error, :not_found}
          | {:error, :already_sent}
  defp do_cancel_queued(id, state)

  defp do_cancel_queued(id, state) when is_binary(id) do
    context = Context.remove_unpersisted(state.context, id)

    if context != state.context do
      state = %{state | context: context}
      broadcast(state, :message_cancelled, %{id: id})
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  defp do_cancel_queued(id, state) when is_integer(id) and id >= 0 do
    {:reply, {:error, :already_sent}, state}
  end

  @spec turn_messages(t()) :: [Message.t()]
  defp turn_messages(state)

  defp turn_messages(%__MODULE__{} = state) do
    messages = state.context.messages
    stream_start = state.turn.stream_start

    Enum.drop(messages, max(0, stream_start - 1))
  end

  @spec fire_turn_end_hook(t(), [Message.t()]) :: t()
  defp fire_turn_end_hook(state, messages)

  defp fire_turn_end_hook(
         %__MODULE__{hooks: %Hooks{turn_end: module}} = state,
         [_ | _] = messages
       )
       when is_atom(module) and not is_nil(module) do
    agent_id = state.identity.id
    sidecar_node = state.hooks.sidecar_node

    Task.Supervisor.start_child(Planck.Agent.TaskSupervisor, fn ->
      Hooks.TurnEnd.reflect(module, agent_id, messages, sidecar_node)
    end)

    state
  end

  defp fire_turn_end_hook(%__MODULE__{} = state, _messages) do
    state
  end
end
