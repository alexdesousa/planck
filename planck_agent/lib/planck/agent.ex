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
  | `:usage_delta` | `delta`, `total` |
  | `:tool_start` | `id`, `name`, `args` |
  | `:tool_end` | `id`, `name`, `result`, `error` |
  | `:rewind` | `message_count` |
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

  alias Planck.Agent.{AIBehaviour, Message, Tool}
  alias Planck.AI.Context

  @type agent :: pid() | atom() | {:via, module(), term()}

  # ---------------------------------------------------------------------------
  # State
  # ---------------------------------------------------------------------------

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
    turn_index: 0,
    turn_checkpoints: [],
    pending_tool_calls: [],
    text_buffer: "",
    thinking_buffer: "",
    usage: %{input_tokens: 0, output_tokens: 0}
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

  @doc "Send a user message and kick off the agent loop (async)."
  @spec prompt(agent(), String.t() | [Planck.AI.Message.content_part()], keyword()) :: :ok
  def prompt(agent, content, opts \\ []) do
    GenServer.cast(agent, {:prompt, content, opts})
  end

  @doc "Cancel in-flight streaming and tool execution. Agent returns to `:idle`."
  @spec abort(agent()) :: :ok
  def abort(agent) do
    GenServer.cast(agent, :abort)
  end

  @doc "Stop the agent. Cancels any in-flight work and removes it from the supervisor."
  @spec stop(agent()) :: :ok
  def stop(agent) do
    GenServer.stop(agent)
  end

  @doc """
  Remove the last `n` user-initiated turns from the agent's message history.

  Only takes effect when the agent is idle — ignored while streaming or executing
  tools. Syncs the session store if a `session_id` is set.
  """
  @spec rewind(agent(), pos_integer()) :: :ok
  def rewind(agent, n \\ 1) do
    GenServer.cast(agent, {:rewind, n})
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
      on_compact: Keyword.get(opts, :on_compact)
    }

    register_agent(state)
    link_to_orchestrator(state)

    # Orchestrators trap exits so they survive individual worker crashes.
    if role == :orchestrator, do: Process.flag(:trap_exit, true)

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    info = %{
      id: state.id,
      name: state.name,
      description: state.description,
      type: state.type,
      role: state.role,
      status: state.status,
      turn_index: state.turn_index,
      usage: state.usage
    }

    {:reply, info, state}
  end

  @impl true
  def handle_cast({:prompt, content, _opts}, state) do
    parts = normalize_content(content)
    msg = Message.new(:user, parts)
    checkpoint = length(state.messages)

    new_state = %{
      state
      | messages: state.messages ++ [msg],
        turn_checkpoints: [checkpoint | state.turn_checkpoints]
    }

    maybe_append_to_session(new_state, msg)
    broadcast(new_state, :turn_start, %{index: new_state.turn_index})
    {:noreply, %{new_state | status: :streaming}, {:continue, :run_llm}}
  end

  @impl true
  def handle_cast({:rewind, _n}, %{status: status} = state) when status != :idle do
    {:noreply, state}
  end

  def handle_cast({:rewind, n}, state) do
    case Enum.at(state.turn_checkpoints, n - 1) do
      nil ->
        {:noreply, state}

      checkpoint ->
        new_state = %{
          state
          | messages: Enum.take(state.messages, checkpoint),
            turn_checkpoints: Enum.drop(state.turn_checkpoints, n)
        }

        maybe_truncate_session(new_state, checkpoint)
        broadcast(new_state, :rewind, %{message_count: checkpoint})
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast(:abort, state) do
    cancel_stream(state)
    {:noreply, reset_streaming(state)}
  end

  @impl true
  def handle_cast({:add_tool, tool}, state) do
    {:noreply, %{state | tools: Map.put(state.tools, tool.name, tool)}}
  end

  @impl true
  def handle_cast({:remove_tool, name}, state) do
    {:noreply, %{state | tools: Map.delete(state.tools, name)}}
  end

  @impl true
  def handle_continue(:run_llm, state) do
    {messages, state} = apply_compact(state)
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

    {:noreply,
     %{
       state
       | stream_task: task,
         stream_ref: ref,
         status: :streaming,
         turn_index: state.turn_index + 1
     }}
  end

  @impl true
  def handle_continue({:execute_tools, tool_calls}, state) do
    parent = self()

    results =
      tool_calls
      |> Task.async_stream(
        fn %{id: id, name: name, args: args} = call ->
          broadcast(state, :tool_start, %{id: id, name: name, args: args})

          result =
            case Map.get(state.tools, name) do
              nil -> {:error, "unknown tool: #{name}"}
              %Tool{execute_fn: fun} -> safe_execute(fun, id, args)
            end

          send(parent, {:tool_result, id, name, result})
          {call, result}
        end,
        max_concurrency: 4,
        timeout: Keyword.get(state.opts, :tool_timeout, 300_000),
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, {call, result}} ->
          error = match?({:error, _}, result)

          broadcast(state, :tool_end, %{
            id: call.id,
            name: call.name,
            result: result,
            error: error
          })

          {call.id, result}

        {:exit, reason} ->
          Logger.warning("Tool task exited: #{inspect(reason)}")
          nil
      end)
      |> Enum.reject(&is_nil/1)

    tool_result_msg = build_tool_result_message(results)

    new_state = %{state | messages: state.messages ++ [tool_result_msg], pending_tool_calls: []}
    maybe_append_to_session(new_state, tool_result_msg)
    {:noreply, %{new_state | status: :streaming}, {:continue, :run_llm}}
  end

  @impl true
  def handle_info({:stream_event, ref, event}, %{stream_ref: ref} = state) do
    {:noreply, process_event(state, event)}
  end

  def handle_info({:stream_event, _stale, _event}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:stream_done, ref}, %{stream_ref: ref} = state) do
    pending = state.pending_tool_calls
    assistant_msg = build_assistant_message(state)

    new_state =
      %{state | messages: state.messages ++ [assistant_msg]}
      |> reset_streaming()

    maybe_append_to_session(new_state, assistant_msg)

    case pending do
      [] ->
        broadcast(new_state, :turn_end, %{message: assistant_msg, usage: new_state.usage})
        {:noreply, new_state}

      calls ->
        {:noreply, %{new_state | status: :executing_tools}, {:continue, {:execute_tools, calls}}}
    end
  end

  def handle_info({:stream_done, _stale}, state) do
    {:noreply, state}
  end

  def handle_info({:tool_result, _id, _name, _result}, state) do
    # Results are collected synchronously in execute_tools via Task.async_stream.
    # This clause handles any late-arriving messages after an abort.
    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_response, response}, state) do
    msg = Message.new({:custom, :agent_response}, [{:text, response}])
    new_state = %{state | messages: state.messages ++ [msg]}
    maybe_append_to_session(new_state, msg)

    if state.status == :idle do
      broadcast(new_state, :turn_start, %{index: new_state.turn_index})
      {:noreply, %{new_state | status: :streaming}, {:continue, :run_llm}}
    else
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, state) do
    broadcast(state, :worker_exit, %{pid: pid, reason: reason})
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state), do: cancel_stream(state)

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec link_to_orchestrator(%__MODULE__{}) :: :ok
  defp link_to_orchestrator(%{delegator_id: nil}), do: :ok

  defp link_to_orchestrator(%{delegator_id: id}) do
    case whereis(id) do
      {:ok, pid} -> Process.link(pid)
      _ -> :ok
    end
  end

  @spec register_agent(%__MODULE__{}) :: :ok
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

  @spec broadcast(%__MODULE__{}, atom(), map()) :: :ok
  defp broadcast(%{id: id, session_id: session_id}, type, payload) do
    event = {:agent_event, type, payload}
    Phoenix.PubSub.broadcast(Planck.Agent.PubSub, "agent:#{id}", event)

    if session_id do
      session_event = {:agent_event, type, Map.put(payload, :agent_id, id)}
      Phoenix.PubSub.broadcast(Planck.Agent.PubSub, "session:#{session_id}", session_event)
    end
  end

  @spec maybe_append_to_session(%__MODULE__{}, Message.t()) :: :ok
  defp maybe_append_to_session(%{session_id: nil}, _msg), do: :ok

  defp maybe_append_to_session(%{session_id: sid, id: agent_id}, msg) do
    Planck.Agent.Session.append(sid, agent_id, msg)
  end

  @spec maybe_truncate_session(%__MODULE__{}, non_neg_integer()) :: :ok
  defp maybe_truncate_session(%{session_id: nil}, _count), do: :ok

  defp maybe_truncate_session(%{session_id: sid, id: agent_id}, count) do
    Planck.Agent.Session.truncate_agent(sid, agent_id, count)
  end

  @spec process_event(%__MODULE__{}, Planck.AI.Stream.t()) :: %__MODULE__{}
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

    new_state = %{state | usage: usage}

    broadcast(new_state, :usage_delta, %{
      delta: %{input_tokens: i, output_tokens: o},
      total: usage
    })

    new_state
  end

  defp process_event(state, _other), do: state

  @spec build_assistant_message(%__MODULE__{}) :: Message.t()
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

  @spec apply_compact(%__MODULE__{}) :: {[Message.t()], %__MODULE__{}}
  defp apply_compact(%{on_compact: nil, messages: messages} = state) do
    {messages_since_last_summary(messages), state}
  end

  defp apply_compact(%{on_compact: fun, messages: messages} = state) do
    recent = messages_since_last_summary(messages)

    case fun.(recent) do
      :skip ->
        {recent, state}

      {:compact, summary_msg, kept} ->
        prefix_len = length(messages) - length(recent)
        prefix = Enum.take(messages, prefix_len)
        new_messages = prefix ++ [summary_msg | kept]
        new_state = %{state | messages: new_messages}
        maybe_append_to_session(new_state, summary_msg)
        {[summary_msg | kept], new_state}
    end
  end

  @spec messages_since_last_summary([Message.t()]) :: [Message.t()]
  defp messages_since_last_summary(messages) do
    reversed = Enum.reverse(messages)
    {tail_rev, rest} = Enum.split_while(reversed, &(not match?(%{role: {:custom, :summary}}, &1)))

    case rest do
      [] -> messages
      [summary_msg | _] -> [summary_msg | Enum.reverse(tail_rev)]
    end
  end

  @spec cancel_stream(%__MODULE__{}) :: :ok
  defp cancel_stream(%{stream_task: nil}), do: :ok

  defp cancel_stream(%{stream_task: task}) do
    Task.Supervisor.terminate_child(Planck.Agent.TaskSupervisor, task)
  end

  @spec reset_streaming(%__MODULE__{}) :: %__MODULE__{}
  defp reset_streaming(state) do
    %{
      state
      | status: :idle,
        stream_task: nil,
        stream_ref: nil,
        text_buffer: "",
        thinking_buffer: "",
        pending_tool_calls: []
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
