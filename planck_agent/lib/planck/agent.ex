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

  require Logger

  alias Planck.Agent.Hooks

  alias Planck.Agent.{
    AIBehaviour,
    Message,
    MessageBuilder,
    Session,
    SessionStore,
    SkillIndex,
    StreamBuffer,
    Tool,
    ToolRunner,
    TurnContext,
    TurnState,
    Usage
  }

  alias Planck.AI.Context

  @typedoc "A reference to a running agent — pid, registered name, or via-tuple."
  @type agent :: pid() | atom() | {:via, module(), term()}

  # ---------------------------------------------------------------------------
  # State
  # ---------------------------------------------------------------------------

  @typedoc """
  Internal GenServer state for an agent.

  Public fields (readable via `get_state/1` or `get_info/1`):
  - `id` — unique agent identifier
  - `name` / `description` / `type` — display metadata set at start time
  - `team_id` — registry namespace shared by all agents in the same team
  - `session_id` — SQLite session this agent persists messages to; `nil` for
    ephemeral agents
  - `delegator_id` — id of the orchestrator that spawned this worker; `nil` for
    orchestrators
  - `role` — `:orchestrator` (has `spawn_agent` tool) or `:worker`
  - `model` — the `Planck.AI.Model` the agent is configured to use
  - `system_prompt` — prepended to every LLM context
  - `cwd` — working directory for the session; used to locate `AGENTS.md`
  - `messages` — full in-memory conversation history (`Message.t()` list)
  - `tools` — map of tool name → `Tool.t()` available to this agent
  - `status` — `:idle`, `:streaming`, or `:executing_tools`
  - `turn_state` — monotonically increasing turn counter and checkpoint stack
  - `usage` — accumulated token counts and cost for this session

  Internal fields (not part of the public API):
  - `stream_task` / `stream_ref` — in-flight async LLM stream
  - `stream_start` — length of `messages` when the current stream began; used to
    detect messages appended *during* streaming that the LLM did not see
  - `stream_buffer` — accumulates text/thinking/tool-call deltas during streaming
  - `tool_runner` — tracks in-flight tool tasks and their accumulated results
  - `compactor` — resolved module atom for context compaction; `nil` uses the
    built-in LLM-based compactor
  - `prompt_hook` — resolved module atom for per-turn system prompt injection
    (prepend/append); `nil` means no injection
  - `turn_end_hook` — resolved module atom called after every turn ends;
    `nil` means no post-turn reflection
  - `sidecar_node` — connected sidecar node; shared by all hook dispatch calls
  - `skills` — frozen skill index for system prompt building and tool dispatch
  - `opts` — pass-through keyword options (e.g. `tool_timeout`)
  - `available_models` — model catalog used by `list_models` and `spawn_agent`
  """
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          description: String.t() | nil,
          type: String.t() | nil,
          team_id: String.t() | nil,
          session_id: String.t() | nil,
          delegator_id: String.t() | nil,
          role: :orchestrator | :worker,
          model: Planck.AI.Model.t() | nil,
          compactor: module() | nil,
          prompt_hook: module() | nil,
          turn_end_hook: module() | nil,
          sidecar_node: atom() | nil,
          skills: SkillIndex.t(),
          cwd: String.t(),
          system_prompt: String.t(),
          messages: [Message.t()],
          tools: %{String.t() => Tool.t()},
          opts: keyword(),
          available_models: [Planck.AI.Model.t()],
          status: :idle | :streaming | :executing_tools,
          stream_task: Task.t() | nil,
          stream_ref: reference() | nil,
          stream_start: non_neg_integer(),
          turn_state: TurnState.t(),
          stream_buffer: StreamBuffer.t(),
          usage: Usage.t(),
          tool_runner: ToolRunner.t()
        }

  defstruct [
    :id,
    :name,
    :description,
    :type,
    :team_id,
    :session_id,
    :delegator_id,
    :role,
    :model,
    compactor: nil,
    prompt_hook: nil,
    turn_end_hook: nil,
    sidecar_node: nil,
    skills: %SkillIndex{},
    cwd: "",
    system_prompt: "",
    messages: [],
    tools: %{},
    opts: [],
    available_models: [],
    status: :idle,
    stream_task: nil,
    stream_ref: nil,
    stream_start: 0,
    turn_state: %TurnState{},
    stream_buffer: %StreamBuffer{},
    usage: %Usage{},
    tool_runner: %ToolRunner{}
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Start an agent under a supervisor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, [])
  end

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.fetch!(opts, :id),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @doc "Send a user message and kick off the agent loop. Returns once the agent status is :streaming."
  @spec prompt(agent(), String.t() | [Planck.AI.Message.content_part()], keyword()) :: :ok
  def prompt(agent, content, opts \\ []) do
    GenServer.call(agent, {:prompt, content, opts})
  end

  @doc """
  Trigger the agent to run an LLM turn without adding a new user message.

  Used after session resume when a recovery context message is already present
  in the agent's history and just needs to be acted upon.
  """
  @spec nudge(agent()) :: :ok
  def nudge(agent) do
    GenServer.cast(agent, :nudge)
  end

  @doc """
  Cancel in-flight streaming and tool execution. Blocks until the agent has
  returned to `:idle` (or started a follow-up turn for any queued messages).
  """
  @spec abort(agent()) :: :ok
  def abort(agent) do
    GenServer.call(agent, :abort)
  end

  @doc """
  Truncate the session to strictly before `message_id`, then reload the
  agent's in-memory message history from the DB (the source of truth).
  `turn_checkpoints` is rebuilt from the reloaded message list.

  Only meaningful for agents with a `session_id`. A no-op for ephemeral agents.
  """
  @spec rewind_to_message(agent(), pos_integer()) :: :ok
  def rewind_to_message(agent, message_id) do
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
  def checkpoint(agent, summary_text) do
    GenServer.call(agent, {:checkpoint, summary_text})
  end

  @doc "Stop the agent. Cancels any in-flight work and removes it from the supervisor."
  @spec stop(agent()) :: :ok
  def stop(agent) do
    GenServer.stop(agent)
  end

  @doc "Synchronous state snapshot."
  @spec get_state(agent()) :: map()
  def get_state(agent) do
    GenServer.call(agent, :get_state)
  end

  @doc "Lightweight summary: id, name, description, type, role, status, turn_index, usage."
  @spec get_info(agent()) :: map()
  def get_info(agent) do
    GenServer.call(agent, :get_info)
  end

  @doc "Estimate the number of tokens currently in the agent's context window."
  @spec estimate_tokens(agent()) :: non_neg_integer()
  def estimate_tokens(agent) do
    GenServer.call(agent, :estimate_tokens)
  end

  @doc "Replace the model used for subsequent LLM turns without interrupting the current state."
  @spec change_model(agent(), Planck.AI.Model.t()) :: :ok
  def change_model(agent, model) do
    GenServer.call(agent, {:change_model, model})
  end

  @doc """
  Subscribe the calling process to `{:agent_event, type, payload}` messages.

  Accepts either an agent id string or a pid/name. The pid form resolves the id
  via `get_info/1` — prefer passing the id directly when available.
  """
  @spec subscribe(String.t() | agent()) :: :ok | {:error, term()}
  def subscribe(agent_id) when is_binary(agent_id) do
    Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "agent:#{agent_id}")
  end

  def subscribe(agent) do
    %{id: id} = get_info(agent)
    Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "agent:#{id}")
  end

  @doc "Resolve an agent id to its pid via the Registry."
  @spec whereis(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def whereis(id) do
    case Registry.lookup(Planck.Agent.Registry, {:agent, id}) do
      [{pid, _}] -> {:ok, pid}
      _ -> {:error, :not_found}
    end
  end

  @doc "Add a tool at runtime."
  @spec add_tool(agent(), Tool.t()) :: :ok
  def add_tool(agent, tool) do
    GenServer.cast(agent, {:add_tool, tool})
  end

  @doc "Remove a tool by name at runtime."
  @spec remove_tool(agent(), String.t()) :: :ok
  def remove_tool(agent, name) do
    GenServer.cast(agent, {:remove_tool, name})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    tool_list = Keyword.get(opts, :tools, [])
    tool_map = Map.new(tool_list, &{&1.name, &1})
    role = if Map.has_key?(tool_map, "spawn_agent"), do: :orchestrator, else: :worker

    state = %__MODULE__{
      id: Keyword.fetch!(opts, :id),
      name: Keyword.get(opts, :name),
      description: Keyword.get(opts, :description),
      type: Keyword.get(opts, :type),
      team_id: Keyword.get(opts, :team_id),
      session_id: Keyword.get(opts, :session_id),
      delegator_id: Keyword.get(opts, :delegator_id),
      role: role,
      model: Keyword.fetch!(opts, :model),
      cwd: Keyword.get(opts, :cwd, ""),
      system_prompt: Keyword.get(opts, :system_prompt, ""),
      compactor: Keyword.get(opts, :compactor),
      prompt_hook: Keyword.get(opts, :prompt_hook),
      turn_end_hook: Keyword.get(opts, :turn_end_hook),
      sidecar_node: Keyword.get(opts, :sidecar_node),
      skills: SkillIndex.from_opts(opts),
      tools: tool_map,
      opts: Keyword.get(opts, :opts, []),
      available_models: Keyword.get(opts, :available_models, []),
      usage: Usage.from_opts(opts)
    }

    register_agent(state)
    link_to_orchestrator(state)

    # Orchestrators trap exits so they survive individual worker crashes.
    if role == :orchestrator, do: Process.flag(:trap_exit, true)

    # Notify session subscribers so UIs can refresh the agent list.
    if state.delegator_id, do: broadcast(state, :worker_spawned, %{})

    # Load existing session history (if any) and strip orphaned tool-call turns
    # left by a previous crash. Deferred to a continue so the process is
    # registered before any synchronous Session calls run.
    if state.session_id do
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
      id: state.id,
      name: state.name,
      description: state.description,
      type: state.type,
      role: state.role,
      status: state.status,
      turn_index: state.turn_state.index,
      usage: %{input_tokens: state.usage.input_tokens, output_tokens: state.usage.output_tokens},
      cost: state.usage.cost
    }

    {:reply, info, state}
  end

  def handle_call({:change_model, model}, _from, state) do
    {:reply, :ok, %{state | model: model}}
  end

  def handle_call(:estimate_tokens, _from, state) do
    {:reply, Message.estimate_tokens(state.messages), state}
  end

  def handle_call({:prompt, content, _opts}, _from, %{status: :idle} = state) do
    do_prompt(content, state)
  end

  def handle_call({:prompt, content, _opts}, _from, state) do
    # Agent is busy — append without persisting yet. Persisting now would give
    # the queued message a db_id smaller than the current turn's assistant
    # response, breaking edit-message truncation order. The message is flushed
    # to the session in handle_continue(:run_llm) after the current turn ends.
    parts = MessageBuilder.normalize_content(content)
    msg = Message.new(:user, parts)
    {:reply, :ok, %{state | messages: state.messages ++ [msg]}}
  end

  def handle_call(:abort, _from, state) do
    cancel_stream(state)
    cancel_running_tools(state)
    new_state = reset_streaming(state)

    if TurnContext.has_pending_input?(new_state.messages, new_state.stream_start) do
      broadcast(new_state, :turn_start, %{index: new_state.turn_state.index})
      {:reply, :ok, %{new_state | status: :streaming}, {:continue, {:run_llm, :new_turn}}}
    else
      {:reply, :ok, new_state}
    end
  end

  def handle_call({:checkpoint, summary_text}, _from, state) do
    msg = Message.new({:custom, :summary}, [{:text, summary_text}])
    msg = persist_message(state, msg)
    {:reply, :ok, %{state | messages: state.messages ++ [msg]}}
  end

  @impl true
  def handle_cast(event, state)

  def handle_cast(:nudge, %{status: :idle} = state) do
    broadcast(state, :turn_start, %{index: state.turn_state.index})
    {:noreply, %{state | status: :streaming}, {:continue, {:run_llm, :new_turn}}}
  end

  def handle_cast(:nudge, state) do
    {:noreply, state}
  end

  def handle_cast({:rewind_to_message, _message_id}, %{session_id: nil} = state) do
    {:noreply, state}
  end

  def handle_cast({:rewind_to_message, message_id}, state) do
    Session.truncate_after(state.session_id, message_id)
    {:noreply, reload_messages_from_session(state)}
  end

  def handle_cast({:add_tool, tool}, state) do
    {:noreply, %{state | tools: Map.put(state.tools, tool.name, tool)}}
  end

  def handle_cast({:remove_tool, name}, state) do
    {:noreply, %{state | tools: Map.delete(state.tools, name)}}
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
    {:noreply, do_run_llm(state, :new_turn)}
  end

  def handle_continue({:execute_tools, calls}, state) do
    {:noreply, start_tool_tasks(calls, state)}
  end

  @impl true
  def handle_info(event, state)

  def handle_info({:stream_event, ref, event}, %{stream_ref: ref} = state) do
    {:noreply, process_event(state, event)}
  end

  def handle_info({:stream_event, _stale, _event}, state) do
    {:noreply, state}
  end

  def handle_info({:stream_done, ref}, %{stream_ref: ref} = state) do
    do_stream_done(state)
  end

  def handle_info({:stream_done, _stale}, state) do
    {:noreply, state}
  end

  def handle_info({:tool_done, call_id, name, result}, state) do
    case ToolRunner.mark_done(state.tool_runner, call_id, result) do
      :not_running ->
        {:noreply, state}

      {:ok, runner} ->
        error = match?({:error, _}, result)
        broadcast(state, :tool_end, %{id: call_id, name: name, result: result, error: error})
        new_state = %{state | tool_runner: runner}

        if ToolRunner.done?(runner) do
          {:noreply, finish_tool_execution(runner.results, new_state), {:continue, :run_llm}}
        else
          {:noreply, new_state}
        end
    end
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
    cancel_stream(state)
    cancel_running_tools(state)
  end

  # ---------------------------------------------------------------------------
  # Callback implementations
  # ---------------------------------------------------------------------------

  @spec do_prompt(String.t() | [Planck.AI.Message.content_part()], t()) ::
          {:reply, :ok, t(), {:continue, {:run_llm, :new_turn}}}
  defp do_prompt(content, state) do
    parts = MessageBuilder.normalize_content(content)
    msg = Message.new(:user, parts)
    checkpoint = length(state.messages)
    msg = persist_message(state, msg)

    new_state = %{
      state
      | messages: state.messages ++ [msg],
        turn_state: TurnState.push_checkpoint(state.turn_state, checkpoint)
    }

    broadcast(new_state, :turn_start, %{index: new_state.turn_state.index})
    {:reply, :ok, %{new_state | status: :streaming}, {:continue, {:run_llm, :new_turn}}}
  end

  defp do_run_llm(state, turn_type) do
    {messages, state} = apply_compact(state)
    state = flush_unpersisted_messages(state)

    # Only advance stream_start for fresh turns. Tool continuations keep the
    # original stream_start so any user message queued during tool execution
    # remains detectable by maybe_turn_start after the turn ends.
    stream_start =
      case turn_type do
        :new_turn -> length(state.messages)
        :continuation -> state.stream_start
      end

    ai_tools = state.tools |> Map.values() |> Enum.map(&Tool.to_ai_tool/1)
    system = build_system_prompt(state)

    context = %Context{
      system: presence(system),
      messages: Message.to_ai_messages(messages),
      tools: ai_tools
    }

    ref = make_ref()
    parent = self()

    {:ok, task} =
      Task.Supervisor.start_child(Planck.Agent.TaskSupervisor, fn ->
        try do
          AIBehaviour.client().stream(state.model, context, state.opts)
          |> Enum.each(fn event -> send(parent, {:stream_event, ref, event}) end)
        rescue
          e -> send(parent, {:stream_event, ref, {:error, Exception.message(e)}})
        catch
          kind, reason ->
            send(parent, {:stream_event, ref, {:error, "#{kind}: #{inspect(reason)}"}})
        end

        send(parent, {:stream_done, ref})
      end)

    %{
      state
      | stream_task: task,
        stream_ref: ref,
        stream_start: stream_start,
        status: :streaming,
        turn_state: TurnState.advance(state.turn_state)
    }
  end

  @spec start_tool_tasks([map()], t()) :: t()
  defp start_tool_tasks(tool_calls, state) do
    parent = self()

    entries =
      Enum.map(tool_calls, fn %{id: id, name: name, args: args} ->
        broadcast(state, :tool_start, %{id: id, name: name, args: args})
        execute_fn = resolve_tool_fn(state.tools, state.id, name, id, args)

        {:ok, pid} =
          Task.Supervisor.start_child(Planck.Agent.TaskSupervisor, fn ->
            result =
              try do
                execute_fn.()
              rescue
                e -> {:error, Exception.message(e)}
              catch
                kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
              end

            send(parent, {:tool_done, id, name, result})
          end)

        {id, name, pid}
      end)

    %{state | tool_runner: ToolRunner.start(entries), status: :executing_tools}
  end

  @spec finish_tool_execution(list(), t()) :: t()
  defp finish_tool_execution(results, state) do
    tool_result_msg = results |> Enum.reverse() |> MessageBuilder.build_tool_result()
    tool_result_msg = persist_message(state, tool_result_msg)

    %{
      state
      | messages: state.messages ++ [tool_result_msg],
        status: :streaming
    }
  end

  @spec resolve_tool_fn(%{String.t() => Tool.t()}, String.t(), String.t(), String.t(), map()) ::
          (-> {:ok, String.t()} | {:error, term()})
  defp resolve_tool_fn(tools, agent_id, name, id, args) do
    case Map.get(tools, name) do
      nil ->
        fn -> {:error, "unknown tool: #{name}"} end

      %Tool{} = tool ->
        fn -> run_tool(tool, agent_id, id, args) end
    end
  end

  @spec run_tool(Tool.t(), String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  defp run_tool(%Tool{execute_fn: fun} = tool, agent_id, id, args) do
    with :ok <- Tool.validate_args(tool, args) do
      safe_execute(fun, agent_id, id, args)
    end
  end

  @spec cancel_running_tools(t()) :: :ok
  defp cancel_running_tools(state) do
    ToolRunner.cancel_all(state.tool_runner)
  end

  @spec do_stream_done(t()) ::
          {:noreply, t()} | {:noreply, t(), {:continue, {:execute_tools, [map()]}}}
  defp do_stream_done(state) do
    pending = state.stream_buffer.calls
    assistant_msg = MessageBuilder.build_assistant(state.stream_buffer)

    assistant_msg = persist_message(state, assistant_msg)

    new_state =
      %{state | messages: state.messages ++ [assistant_msg]}
      |> reset_streaming()

    case pending do
      [] ->
        broadcast(new_state, :turn_end, %{message: assistant_msg, usage: new_state.usage})
        fire_turn_end_hook(new_state)
        maybe_turn_start(new_state)

      calls ->
        {:noreply, %{new_state | status: :executing_tools}, {:continue, {:execute_tools, calls}}}
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
    new_state = %{state | messages: state.messages ++ [msg]}

    if state.status == :idle do
      broadcast(new_state, :turn_start, %{index: new_state.turn_state.index})
      {:noreply, %{new_state | status: :streaming}, {:continue, {:run_llm, :new_turn}}}
    else
      {:noreply, new_state}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec link_to_orchestrator(t()) :: :ok
  defp link_to_orchestrator(%{delegator_id: nil}), do: :ok

  defp link_to_orchestrator(%{delegator_id: id}) do
    case whereis(id) do
      {:ok, pid} -> Process.link(pid)
      _ -> :ok
    end
  end

  @spec register_agent(t()) :: :ok
  defp register_agent(%{id: id, team_id: team_id, type: type, name: name, description: desc}) do
    Registry.register(Planck.Agent.Registry, {:agent, id}, nil)

    if team_id do
      meta = %{id: id, type: type, name: name, description: desc}
      Registry.register(Planck.Agent.Registry, {team_id, :member}, meta)
      if type, do: Registry.register(Planck.Agent.Registry, {team_id, type}, id)
      if name, do: Registry.register(Planck.Agent.Registry, {team_id, name}, id)
    end

    :ok
  end

  @spec broadcast(t(), atom(), map()) :: :ok
  defp broadcast(%{id: id, session_id: session_id}, type, payload) do
    event = {:agent_event, type, payload}
    Phoenix.PubSub.broadcast(Planck.Agent.PubSub, "agent:#{id}", event)

    if session_id do
      session_event = {:agent_event, type, Map.put(payload, :agent_id, id)}
      Phoenix.PubSub.broadcast(Planck.Agent.PubSub, "session:#{session_id}", session_event)
    end
  end

  @spec flush_unpersisted_messages(t()) :: t()
  defp flush_unpersisted_messages(state) do
    case SessionStore.flush_unpersisted(state.session_id, state.id, state.messages) do
      :noop -> state
      :flushed -> reload_messages_from_session(state)
    end
  end

  @spec reload_messages_from_session(t()) :: t()
  defp reload_messages_from_session(state), do: do_load_session(state, strip_orphans: true)

  @spec load_messages_from_session(t()) :: t()
  defp load_messages_from_session(state), do: do_load_session(state, strip_orphans: false)

  @spec do_load_session(t(), keyword()) :: t()
  defp do_load_session(state, opts) do
    case SessionStore.load_messages(state.session_id, state.id, opts) do
      {:ok, messages} ->
        turn_state = TurnState.rebuild_checkpoints(state.turn_state, messages)
        %{state | messages: messages, turn_state: turn_state}

      :error ->
        state
    end
  end

  # Persist a message and return it with its DB row id set. For ephemeral
  # agents (no session_id), the message is returned unchanged.
  @spec persist_usage(t()) :: :ok
  defp persist_usage(state) do
    SessionStore.persist_usage(state.session_id, state.id, state.usage)
  end

  @spec persist_message(t(), Message.t()) :: Message.t()
  defp persist_message(state, msg) do
    SessionStore.persist_message(state.session_id, state.id, msg)
  end

  @spec process_event(t(), Planck.AI.Stream.t()) :: t()
  defp process_event(state, {:text_delta, text}) do
    broadcast(state, :text_delta, %{text: text})
    %{state | stream_buffer: StreamBuffer.append_text(state.stream_buffer, text)}
  end

  defp process_event(state, {:thinking_delta, text}) do
    broadcast(state, :thinking_delta, %{text: text})
    %{state | stream_buffer: StreamBuffer.append_thinking(state.stream_buffer, text)}
  end

  defp process_event(state, {:tool_call_complete, call}) do
    %{state | stream_buffer: StreamBuffer.add_call(state.stream_buffer, call)}
  end

  defp process_event(state, {:error, reason}) do
    broadcast(state, :error, %{reason: reason})
    reset_streaming(state)
  end

  defp process_event(state, {:done, %{usage: %{input_tokens: i, output_tokens: o}}}) do
    new_usage = Usage.add_turn(state.usage, i, o, state.model)
    turn_cost = new_usage.cost - state.usage.cost
    new_state = %{state | usage: new_usage}

    persist_usage(new_state)

    broadcast(new_state, :usage_delta, %{
      delta: %{
        input_tokens: i,
        output_tokens: o,
        cost: turn_cost
      },
      total: %{
        input_tokens: new_usage.input_tokens,
        output_tokens: new_usage.output_tokens,
        cost: new_usage.cost
      },
      context_tokens: Message.estimate_tokens(new_state.messages)
    })

    new_state
  end

  defp process_event(state, _other), do: state

  @spec apply_compact(t()) :: {[Message.t()], t()}
  defp apply_compact(%__MODULE__{messages: messages} = state) do
    recent = TurnContext.messages_since_last_summary(messages)

    case Hooks.Compactor.compact(state.compactor, state.model, recent, state.sidecar_node) do
      :skip ->
        {recent, state}

      {:compact, %Message{} = summary_msg, kept} ->
        broadcast(state, :compacting, %{})

        summary_msg = persist_message(state, summary_msg)

        prefix_len = length(messages) - length(recent)
        prefix = Enum.take(messages, prefix_len)
        new_messages = prefix ++ [summary_msg | kept]

        new_state = %{state | messages: new_messages}

        refreshed = %{new_state | skills: SkillIndex.refresh(new_state.skills)}
        broadcast(refreshed, :compacted, %{})
        {[summary_msg | kept], refreshed}
    end
  end

  @spec maybe_turn_start(t()) ::
          {:noreply, t()}
          | {:noreply, t(), {:continue, {:run_llm, :new_turn}}}
  defp maybe_turn_start(state)

  defp maybe_turn_start(%__MODULE__{} = state) do
    if TurnContext.has_pending_input?(state.messages, state.stream_start) do
      broadcast(state, :turn_start, %{index: state.turn_state.index})
      {:noreply, %{state | status: :streaming}, {:continue, {:run_llm, :new_turn}}}
    else
      {:noreply, state}
    end
  end

  @spec cancel_stream(t()) :: :ok
  defp cancel_stream(%{stream_task: nil}), do: :ok

  defp cancel_stream(%{stream_task: task}) do
    Task.Supervisor.terminate_child(Planck.Agent.TaskSupervisor, task)
  end

  @spec reset_streaming(t()) :: t()
  defp reset_streaming(state) do
    %{
      state
      | status: :idle,
        stream_task: nil,
        stream_ref: nil,
        stream_buffer: StreamBuffer.new(),
        tool_runner: ToolRunner.new()
    }
  end

  @spec safe_execute(Tool.execute_fn(), String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  defp safe_execute(fun, agent_id, id, args) do
    fun.(agent_id, id, args)
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @spec build_system_prompt(t()) :: String.t()
  defp build_system_prompt(state) do
    Planck.Agent.SystemPrompt.build(%{
      system_prompt: state.system_prompt,
      name: state.name,
      type: state.type,
      tools: state.tools,
      skill_pool: state.skills.pool,
      ranked_skill_names: state.skills.ranked,
      top_skills: state.skills.top_n,
      prompt_hook: state.prompt_hook,
      session_id: state.session_id,
      sidecar_node: state.sidecar_node
    })
  end

  @spec fire_turn_end_hook(t()) :: :ok
  defp fire_turn_end_hook(%{turn_end_hook: nil}), do: :ok

  defp fire_turn_end_hook(state) do
    turn_messages = Enum.drop(state.messages, state.stream_start)

    Task.Supervisor.start_child(Planck.Agent.TaskSupervisor, fn ->
      Hooks.TurnEnd.reflect(
        state.turn_end_hook,
        state.id,
        turn_messages,
        state.sidecar_node
      )
    end)

    :ok
  end

  @spec presence(String.t()) :: String.t() | nil
  defp presence(""), do: nil
  defp presence(str), do: str
end
