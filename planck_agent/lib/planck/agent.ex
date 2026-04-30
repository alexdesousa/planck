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

  alias Planck.Agent.{AIBehaviour, Message, Session, Tool}
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
  - `messages` — full in-memory conversation history (`Message.t()` list)
  - `tools` — map of tool name → `Tool.t()` available to this agent
  - `status` — `:idle`, `:streaming`, or `:executing_tools`
  - `turn_index` — monotonically increasing turn counter
  - `usage` — accumulated `%{input_tokens, output_tokens}` for this session
  - `cost` — accumulated cost in USD; never decreases (rewinding messages does not reduce it)

  Internal fields (not part of the public API):
  - `stream_task` / `stream_ref` — in-flight async LLM stream
  - `stream_start` — length of `messages` when the current stream began; used to
    detect messages appended *during* streaming that the LLM did not see
  - `turn_checkpoints` — message-count stack used internally
  - `pending_tool_calls` — tool calls waiting for execution after stream end
  - `text_buffer` / `thinking_buffer` — partial text accumulated during streaming
  - `on_compact` — optional compaction callback
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
          on_compact: ([Message.t()] -> {:compact, Message.t(), [Message.t()]} | :skip) | nil,
          system_prompt: String.t(),
          messages: [Message.t()],
          tools: %{String.t() => Tool.t()},
          opts: keyword(),
          available_models: [Planck.AI.Model.t()],
          status: :idle | :streaming | :executing_tools,
          stream_task: Task.t() | nil,
          stream_ref: reference() | nil,
          stream_start: non_neg_integer(),
          turn_index: non_neg_integer(),
          turn_checkpoints: [non_neg_integer()],
          pending_tool_calls: [map()],
          text_buffer: String.t(),
          thinking_buffer: String.t(),
          usage: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()},
          cost: float(),
          running_tools: %{String.t() => map()},
          tool_results_acc: list()
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
    :on_compact,
    system_prompt: "",
    messages: [],
    tools: %{},
    opts: [],
    available_models: [],
    status: :idle,
    stream_task: nil,
    stream_ref: nil,
    stream_start: 0,
    turn_index: 0,
    turn_checkpoints: [],
    pending_tool_calls: [],
    text_buffer: "",
    thinking_buffer: "",
    usage: %{input_tokens: 0, output_tokens: 0},
    cost: 0.0,
    running_tools: %{},
    tool_results_acc: []
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
      system_prompt: Keyword.get(opts, :system_prompt, ""),
      tools: tool_map,
      opts: Keyword.get(opts, :opts, []),
      available_models: Keyword.get(opts, :available_models, []),
      on_compact: Keyword.get(opts, :on_compact),
      usage: Keyword.get(opts, :usage, %{input_tokens: 0, output_tokens: 0}),
      cost: Keyword.get(opts, :cost, 0.0)
    }

    register_agent(state)
    link_to_orchestrator(state)

    # Orchestrators trap exits so they survive individual worker crashes.
    if role == :orchestrator, do: Process.flag(:trap_exit, true)

    {:ok, state}
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
      turn_index: state.turn_index,
      usage: state.usage,
      cost: state.cost
    }

    {:reply, info, state}
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
    parts = normalize_content(content)
    msg = Message.new(:user, parts)
    {:reply, :ok, %{state | messages: state.messages ++ [msg]}}
  end

  def handle_call(:abort, _from, state) do
    cancel_stream(state)
    cancel_running_tools(state)
    new_state = reset_streaming(state)

    if has_pending_input?(new_state.messages, new_state.stream_start) do
      broadcast(new_state, :turn_start, %{index: new_state.turn_index})
      {:reply, :ok, %{new_state | status: :streaming}, {:continue, :run_llm}}
    else
      {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_cast(event, state)

  def handle_cast(:nudge, %{status: :idle} = state) do
    broadcast(state, :turn_start, %{index: state.turn_index})
    {:noreply, %{state | status: :streaming}, {:continue, :run_llm}}
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

  def handle_continue(:run_llm, state) do
    {:noreply, do_run_llm(state)}
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
    case Map.pop(state.running_tools, call_id) do
      {nil, _} ->
        # Stale result arriving after an abort — ignore.
        {:noreply, state}

      {_task, remaining} ->
        error = match?({:error, _}, result)
        broadcast(state, :tool_end, %{id: call_id, name: name, result: result, error: error})
        new_results = [{call_id, result} | state.tool_results_acc]

        if map_size(remaining) == 0 do
          {:noreply, finish_tool_execution(new_results, state), {:continue, :run_llm}}
        else
          {:noreply, %{state | running_tools: remaining, tool_results_acc: new_results}}
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
          {:reply, :ok, t(), {:continue, :run_llm}}
  defp do_prompt(content, state) do
    parts = normalize_content(content)
    msg = Message.new(:user, parts)
    checkpoint = length(state.messages)
    msg = persist_message(state, msg)

    new_state = %{
      state
      | messages: state.messages ++ [msg],
        turn_checkpoints: [checkpoint | state.turn_checkpoints]
    }

    broadcast(new_state, :turn_start, %{index: new_state.turn_index})
    {:reply, :ok, %{new_state | status: :streaming}, {:continue, :run_llm}}
  end

  defp do_run_llm(state)

  defp do_run_llm(state) do
    {messages, state} = apply_compact(state)
    state = flush_unpersisted_messages(state)
    stream_start = length(state.messages)
    ai_tools = state.tools |> Map.values() |> Enum.map(&Tool.to_ai_tool/1)

    context = %Context{
      system: presence(state.system_prompt),
      messages: Message.to_ai_messages(messages),
      tools: ai_tools
    }

    ref = make_ref()
    parent = self()

    {:ok, task} =
      Task.Supervisor.start_child(Planck.Agent.TaskSupervisor, fn ->
        AIBehaviour.client().stream(state.model, context, state.opts)
        |> Enum.each(fn event -> send(parent, {:stream_event, ref, event}) end)

        send(parent, {:stream_done, ref})
      end)

    %{
      state
      | stream_task: task,
        stream_ref: ref,
        stream_start: stream_start,
        status: :streaming,
        turn_index: state.turn_index + 1
    }
  end

  @spec start_tool_tasks([map()], t()) :: t()
  defp start_tool_tasks(tool_calls, state) do
    parent = self()

    running =
      Map.new(tool_calls, fn %{id: id, name: name, args: args} ->
        broadcast(state, :tool_start, %{id: id, name: name, args: args})
        execute_fn = resolve_tool_fn(state.tools, name, id, args)

        {:ok, pid} =
          Task.Supervisor.start_child(Planck.Agent.TaskSupervisor, fn ->
            send(parent, {:tool_done, id, name, execute_fn.()})
          end)

        {id, %{name: name, pid: pid}}
      end)

    %{state | running_tools: running, tool_results_acc: [], status: :executing_tools}
  end

  @spec finish_tool_execution(list(), t()) :: t()
  defp finish_tool_execution(results, state) do
    tool_result_msg = results |> Enum.reverse() |> build_tool_result_message()
    tool_result_msg = persist_message(state, tool_result_msg)

    %{
      state
      | messages: state.messages ++ [tool_result_msg],
        pending_tool_calls: [],
        running_tools: %{},
        tool_results_acc: [],
        status: :streaming
    }
  end

  @spec resolve_tool_fn(%{String.t() => Tool.t()}, String.t(), String.t(), map()) ::
          (-> {:ok, String.t()} | {:error, term()})
  defp resolve_tool_fn(tools, name, id, args) do
    case Map.get(tools, name) do
      nil -> fn -> {:error, "unknown tool: #{name}"} end
      %Tool{execute_fn: fun} -> fn -> safe_execute(fun, id, args) end
    end
  end

  @spec cancel_running_tools(t()) :: :ok
  defp cancel_running_tools(%{running_tools: tools}) when map_size(tools) == 0, do: :ok

  defp cancel_running_tools(%{running_tools: tools}) do
    Enum.each(tools, fn {_id, %{pid: pid}} -> Process.exit(pid, :kill) end)
  end

  @spec do_stream_done(t()) ::
          {:noreply, t()} | {:noreply, t(), {:continue, {:execute_tools, [map()]}}}
  defp do_stream_done(state) do
    pending = state.pending_tool_calls
    assistant_msg = build_assistant_message(state)

    assistant_msg = persist_message(state, assistant_msg)

    new_state =
      %{state | messages: state.messages ++ [assistant_msg]}
      |> reset_streaming()

    case pending do
      [] ->
        broadcast(new_state, :turn_end, %{message: assistant_msg, usage: new_state.usage})
        maybe_turn_start(new_state)

      calls ->
        {:noreply, %{new_state | status: :executing_tools}, {:continue, {:execute_tools, calls}}}
    end
  end

  @spec do_agent_response(String.t(), term(), t()) ::
          {:noreply, t()} | {:noreply, t(), {:continue, :run_llm}}
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
      broadcast(new_state, :turn_start, %{index: new_state.turn_index})
      {:noreply, %{new_state | status: :streaming}, {:continue, :run_llm}}
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

  # Persist any messages with a UUID id (not yet written to the session),
  # then reload all messages from the DB to get the canonical id-ordered sequence
  # and rebuild turn_checkpoints. Called at the start of handle_continue(:run_llm)
  # so queued messages are always written AFTER the previous turn's assistant
  # response and the in-memory list reflects the correct DB order.
  @spec flush_unpersisted_messages(t()) :: t()
  defp flush_unpersisted_messages(state)

  defp flush_unpersisted_messages(%__MODULE__{session_id: nil} = state) do
    state
  end

  defp flush_unpersisted_messages(state) do
    unpersisted = Enum.filter(state.messages, &is_binary(&1.id))

    if unpersisted == [] do
      state
    else
      Enum.each(unpersisted, &Session.append(state.session_id, state.id, &1))
      reload_messages_from_session(state)
    end
  end

  # Reload the agent's message history from the session DB and rebuild
  # turn_checkpoints. Used after any operation that changes the canonical
  # sequence (rewind, flush of queued messages).
  @spec reload_messages_from_session(t()) :: t()
  defp reload_messages_from_session(state) do
    case Session.messages(state.session_id, agent_id: state.id) do
      {:ok, rows} ->
        messages = Enum.map(rows, & &1.message)

        checkpoints =
          messages
          |> Enum.with_index()
          |> Enum.filter(fn {msg, _} -> msg.role == :user end)
          |> Enum.map(fn {_, idx} -> idx end)
          |> Enum.reverse()

        %{state | messages: messages, turn_checkpoints: checkpoints}

      _ ->
        # Session unavailable (e.g. no GenServer running for this session_id);
        # keep current in-memory state unchanged.
        state
    end
  end

  # Persist a message and return it with its DB row id set. For ephemeral
  # agents (no session_id), the message is returned unchanged.
  @spec persist_usage(t()) :: :ok
  defp persist_usage(%{session_id: nil}), do: :ok

  defp persist_usage(%{session_id: sid, id: agent_id, usage: usage, cost: cost}) do
    data =
      Jason.encode!(%{
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens,
        cost: cost
      })

    Session.save_metadata(sid, %{"agent_usage:#{agent_id}" => data})
  end

  @spec persist_message(t(), Message.t()) :: Message.t()
  defp persist_message(%{session_id: nil}, msg), do: msg

  defp persist_message(%{session_id: sid, id: agent_id}, msg) do
    case Session.append(sid, agent_id, msg) do
      nil -> msg
      db_id -> %{msg | id: db_id}
    end
  end

  @spec process_event(t(), Planck.AI.Stream.t()) :: t()
  defp process_event(state, {:text_delta, text}) do
    broadcast(state, :text_delta, %{text: text})
    %{state | text_buffer: state.text_buffer <> text}
  end

  defp process_event(state, {:thinking_delta, text}) do
    broadcast(state, :thinking_delta, %{text: text})
    %{state | thinking_buffer: state.thinking_buffer <> text}
  end

  defp process_event(state, {:tool_call_complete, call}) do
    %{state | pending_tool_calls: state.pending_tool_calls ++ [call]}
  end

  defp process_event(state, {:error, reason}) do
    broadcast(state, :error, %{reason: reason})
    reset_streaming(state)
  end

  defp process_event(state, {:done, %{usage: %{input_tokens: i, output_tokens: o}}}) do
    usage = %{
      input_tokens: state.usage.input_tokens + i,
      output_tokens: state.usage.output_tokens + o
    }

    turn_cost =
      case state.model do
        %{cost: %{input: in_rate, output: out_rate}} ->
          (i * in_rate + o * out_rate) / 1_000_000

        _ ->
          0.0
      end

    new_state = %{state | usage: usage, cost: state.cost + turn_cost}

    persist_usage(new_state)

    broadcast(new_state, :usage_delta, %{
      delta: %{
        input_tokens: i,
        output_tokens: o,
        cost: turn_cost
      },
      total: %{
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens,
        cost: new_state.cost
      },
      context_tokens: Message.estimate_tokens(new_state.messages)
    })

    new_state
  end

  defp process_event(state, _other), do: state

  @spec build_assistant_message(t()) :: Message.t()
  defp build_assistant_message(%{
         text_buffer: text,
         thinking_buffer: thinking,
         pending_tool_calls: calls
       }) do
    content =
      Enum.map(calls, fn %{id: id, name: name, args: args} -> {:tool_call, id, name, args} end)
      |> prepend_if(text != "", {:text, text})
      |> prepend_if(thinking != "", {:thinking, thinking})

    Message.new(:assistant, content)
  end

  @spec prepend_if(list(), boolean(), term()) :: list()
  defp prepend_if(list, true, item), do: [item | list]
  defp prepend_if(list, false, _item), do: list

  @spec build_tool_result_message([{String.t(), {:ok, String.t()} | {:error, term()}}]) ::
          Message.t()
  defp build_tool_result_message(results) do
    content =
      Enum.map(results, fn {id, result} ->
        value =
          case result do
            {:ok, v} when is_binary(v) -> v
            {:ok, v} -> inspect(v)
            {:error, reason} when is_binary(reason) -> "Error: #{reason}"
            {:error, reason} -> "Error: #{inspect(reason)}"
          end

        {:tool_result, id, value}
      end)

    Message.new(:tool_result, content)
  end

  @spec apply_compact(t()) :: {[Message.t()], t()}
  defp apply_compact(state)

  defp apply_compact(%__MODULE__{on_compact: nil, messages: messages} = state) do
    {messages_since_last_summary(messages), state}
  end

  defp apply_compact(%__MODULE__{on_compact: fun, messages: messages} = state)
       when is_function(fun) do
    recent = messages_since_last_summary(messages)

    case fun.(recent) do
      :skip ->
        {recent, state}

      {:compact, %Message{} = summary_msg, kept} ->
        broadcast(state, :compacting, %{})

        summary_msg = persist_message(state, summary_msg)

        prefix_len = length(messages) - length(recent)
        prefix = Enum.take(messages, prefix_len)
        new_messages = prefix ++ [summary_msg | kept]
        new_state = %{state | messages: new_messages}

        broadcast(new_state, :compacted, %{})
        {[summary_msg | kept], new_state}
    end
  end

  @spec maybe_turn_start(t()) ::
          {:noreply, t()}
          | {:noreply, t(), {:continue, :run_llm}}
  defp maybe_turn_start(state)

  defp maybe_turn_start(%__MODULE__{} = state) do
    if has_pending_input?(state.messages, state.stream_start) do
      broadcast(state, :turn_start, %{index: state.turn_index})
      {:noreply, %{state | status: :streaming}, {:continue, :run_llm}}
    else
      {:noreply, state}
    end
  end

  # Returns true if any :user or {:custom, :agent_response} message arrived
  # after stream_start — those were appended during streaming and not seen
  # by the LLM.
  @spec has_pending_input?([Message.t()], non_neg_integer()) :: boolean()
  defp has_pending_input?(messages, stream_start) do
    messages
    |> Enum.drop(stream_start)
    |> Enum.any?(fn
      %{role: :user} -> true
      %{role: {:custom, :agent_response}} -> true
      _ -> false
    end)
  end

  @spec messages_since_last_summary([Message.t()]) :: [Message.t()]
  defp messages_since_last_summary(messages) do
    messages
    |> Enum.reverse()
    |> Enum.split_while(&(not match?(%Message{role: {:custom, :summary}}, &1)))
    |> case do
      {_tail_rev, []} -> messages
      {tail_rev, [%Message{} = summary | _]} -> [summary | Enum.reverse(tail_rev)]
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
        text_buffer: "",
        thinking_buffer: "",
        pending_tool_calls: [],
        running_tools: %{},
        tool_results_acc: []
    }
  end

  @spec safe_execute(Tool.execute_fn(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  defp safe_execute(fun, id, args) do
    fun.(id, args)
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @spec normalize_content(String.t() | [Planck.AI.Message.content_part()]) ::
          [Planck.AI.Message.content_part()]
  defp normalize_content(text) when is_binary(text), do: [{:text, text}]
  defp normalize_content(parts) when is_list(parts), do: parts

  @spec presence(String.t()) :: String.t() | nil
  defp presence(""), do: nil
  defp presence(str), do: str
end
