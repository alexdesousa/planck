defmodule Planck.Web.SessionLive do
  use Planck.Web, :live_view

  alias Planck.Agent
  alias Planck.Agent.{Message, Session}
  alias Planck.Headless
  alias Planck.Headless.SidecarManager
  alias Planck.Web.Live.{AgentsSidebar, ChatComponent, StatusBar}

  @impl true
  def mount(_params, session, socket) do
    socket =
      socket
      |> assign(:sessions, [])
      |> assign(:active_session, nil)
      |> assign(:session_name, nil)
      |> assign(:agents, %{})
      |> assign(:agent_order, [])
      |> assign(:orchestrator_id, nil)
      |> assign(:streaming, false)
      |> assign(:waiting, false)
      |> assign(:overlay, nil)
      |> assign(:left_open, false)
      |> assign(:right_open, false)
      |> assign(:edit_message, nil)
      |> assign(:teams, [])
      |> assign(:setup_visible, false)
      |> assign(:model_selector, nil)
      |> assign(:available_models, [])

    if connected?(socket) do
      # Restore locale for the LiveView process (the plug already set it for
      # the HTTP request; LiveView runs in a separate process).
      locale = session["locale"] || get_connect_params(socket)["locale"]
      if locale, do: Gettext.put_locale(Planck.Web.Gettext, locale)

      Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "planck:sidecar")

      sessions = Headless.list_sessions()

      socket =
        case find_initial_session(sessions) do
          {:ok, session_id} -> load_session(socket, session_id)
          {:error, _} -> socket
        end

      teams = Planck.Headless.ResourceStore.get().teams |> Map.keys() |> Enum.sort()
      setup_visible = is_nil(Headless.config().default_model)

      {:ok,
       socket
       |> assign(:sessions, Headless.list_sessions())
       |> assign(:teams, teams)
       |> assign(:setup_visible, setup_visible)
       |> assign(:available_models, Headless.available_models())}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_info(event, socket)

  # ---------------------------------------------------------------------------
  # PubSub events — agent
  # ---------------------------------------------------------------------------

  def handle_info({:agent_event, :turn_start, %{agent_id: agent_id}} = event, socket) do
    {:noreply, do_turn_start(agent_id, event, socket)}
  end

  def handle_info({:agent_event, :turn_end, %{agent_id: agent_id}} = event, socket) do
    {:noreply, do_turn_end(agent_id, event, socket)}
  end

  def handle_info({:agent_event, :usage_delta, _} = event, socket) do
    send_to_sidebar(event)
    send_to_status_bar(event)
    {:noreply, socket}
  end

  def handle_info({:agent_event, :text_delta, %{agent_id: agent_id}} = event, socket) do
    send_to_chats(socket, agent_id, event)
    {:noreply, socket}
  end

  def handle_info({:agent_event, :thinking_delta, %{agent_id: agent_id}} = event, socket) do
    send_to_chats(socket, agent_id, event)
    {:noreply, socket}
  end

  def handle_info({:agent_event, :tool_start, %{agent_id: agent_id}} = event, socket) do
    send_to_chats(socket, agent_id, event)
    {:noreply, socket}
  end

  def handle_info({:agent_event, :tool_end, _payload} = event, socket) do
    send_to_chats(socket, nil, event)
    {:noreply, socket}
  end

  def handle_info({:agent_event, :error, %{agent_id: agent_id}} = event, socket) do
    send_to_chats(socket, agent_id, event)
    {:noreply, socket}
  end

  def handle_info({:agent_event, :compacting, %{agent_id: agent_id}} = event, socket) do
    send_to_chats(socket, agent_id, event)
    {:noreply, socket}
  end

  def handle_info({:agent_event, :compacted, %{agent_id: agent_id}} = event, socket) do
    send_to_chats(socket, agent_id, event)
    {:noreply, socket}
  end

  def handle_info({:agent_event, :worker_spawned, _}, socket) do
    {:noreply, do_refresh_agents(socket)}
  end

  def handle_info({:agent_event, _type, _payload}, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # PubSub events — sidecar
  # ---------------------------------------------------------------------------

  def handle_info({sidecar_event, _} = event, socket)
      when sidecar_event in [:building, :starting, :connected, :disconnected, :exited] do
    send_to_sidebar(event)
    send_to_status_bar(event)
    {:noreply, socket}
  end

  def handle_info({:error, _step, _reason} = event, socket) do
    send_to_sidebar(event)
    send_to_status_bar(event)
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # User events
  # ---------------------------------------------------------------------------

  def handle_info({:prompt_submit, text}, socket) when byte_size(text) > 0 do
    {:noreply, do_prompt_submit(text, socket)}
  end

  def handle_info(:prompt_abort, socket) do
    {:noreply, do_abort(socket)}
  end

  def handle_info(:prompt_abort_all, socket) do
    {:noreply, do_abort_all(socket)}
  end

  def handle_info({:open_edit_message, %{db_id: db_id, text: text}}, socket) do
    {:noreply, assign(socket, :edit_message, %{db_id: db_id, text: text})}
  end

  def handle_info(:close_edit_modal, socket) do
    {:noreply, assign(socket, :edit_message, nil)}
  end

  def handle_info({:switch_session, session_id}, socket) do
    active_ids = socket.assigns.sessions |> Enum.filter(& &1.active) |> Enum.map(& &1.session_id)

    result =
      if session_id in active_ids,
        do: {:ok, session_id},
        else: Headless.resume_session(session_id)

    case result do
      {:ok, sid} ->
        {:noreply,
         socket
         |> load_session(sid)
         |> assign(:sessions, Headless.list_sessions())
         |> assign(:left_open, false)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_info({:delete_session, session_id}, socket) do
    {:noreply, do_delete_session(session_id, socket)}
  end

  def handle_info({:model_changed, agent_id, model_id}, socket) do
    with %{} = model <- Enum.find(socket.assigns.available_models, &(&1.id == model_id)),
         {:ok, pid} <- Agent.whereis(agent_id) do
      Agent.change_model(pid, model)

      agents =
        Map.update(socket.assigns.agents, agent_id, %{}, &Map.put(&1, :model, model_id))

      send_update(AgentsSidebar,
        id: "agents-sidebar",
        action: :refresh_agents,
        agents: agents,
        agent_order: socket.assigns.agent_order
      )

      {:noreply, socket |> assign(:model_selector, nil) |> assign(:agents, agents)}
    else
      _ -> {:noreply, assign(socket, :model_selector, nil)}
    end
  end

  def handle_info(:setup_complete, socket) do
    teams = Planck.Headless.ResourceStore.get().teams |> Map.keys() |> Enum.sort()

    socket =
      socket
      |> assign(:setup_visible, false)
      |> assign(:teams, teams)
      |> assign(:available_models, Headless.available_models())

    case Headless.start_session() do
      {:ok, session_id} ->
        {:noreply,
         socket |> load_session(session_id) |> assign(:sessions, Headless.list_sessions())}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_info({:create_session, team, name}, socket) do
    opts =
      []
      |> then(fn o -> if team != "", do: Keyword.put(o, :template, team), else: o end)
      |> then(fn o -> if name != "", do: Keyword.put(o, :name, name), else: o end)

    socket =
      case Headless.start_session(opts) do
        {:ok, session_id} ->
          socket |> load_session(session_id) |> assign(:sessions, Headless.list_sessions())

        {:error, _} ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info({:resend_message, %{db_id: db_id, text: text}}, socket) do
    {:noreply, do_resend_message(db_id, text, socket)}
  end

  # ---------------------------------------------------------------------------
  # Handled events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event(event, params, socket)

  def handle_event("open_model_selector", %{"id" => agent_id}, socket) do
    agent = Map.get(socket.assigns.agents, agent_id, %{})

    model_selector = %{
      agent_id: agent_id,
      agent_name: agent[:name] || agent[:type] || "agent",
      current_model: agent[:model] || ""
    }

    {:noreply, assign(socket, :model_selector, model_selector)}
  end

  def handle_event("close_model_selector", _params, socket) do
    {:noreply, assign(socket, :model_selector, nil)}
  end

  def handle_event("open_setup", _params, socket) do
    {:noreply, assign(socket, :setup_visible, true)}
  end

  def handle_event("close_setup", _params, socket) do
    if is_nil(Headless.config().default_model) do
      {:noreply, socket}
    else
      {:noreply, assign(socket, :setup_visible, false)}
    end
  end

  def handle_event("open_agent", %{"id" => agent_id}, socket) do
    {:noreply, do_open_agent(agent_id, socket)}
  end

  def handle_event("close_overlay", _params, socket) do
    {:noreply, assign(socket, :overlay, nil)}
  end

  def handle_event("toggle_left", _params, socket) do
    {:noreply, assign(socket, left_open: !socket.assigns.left_open, right_open: false)}
  end

  def handle_event("toggle_right", _params, socket) do
    {:noreply, assign(socket, right_open: !socket.assigns.right_open, left_open: false)}
  end

  def handle_event("close_drawers", _params, socket) do
    {:noreply, assign(socket, left_open: false, right_open: false)}
  end

  # ---------------------------------------------------------------------------
  # Private events
  # ---------------------------------------------------------------------------

  @spec do_refresh_agents(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp do_refresh_agents(socket) do
    session_id = socket.assigns.active_session

    if session_id do
      {agents, agent_order, orchestrator_id} = load_agents(session_id)

      send_update(AgentsSidebar,
        id: "agents-sidebar",
        action: :refresh_agents,
        agents: agents,
        agent_order: agent_order
      )

      socket
      |> assign(:agents, agents)
      |> assign(:agent_order, agent_order)
      |> assign(:orchestrator_id, orchestrator_id)
    else
      socket
    end
  end

  @spec do_turn_start(String.t(), tuple(), Phoenix.LiveView.Socket.t()) ::
          Phoenix.LiveView.Socket.t()
  defp do_turn_start(agent_id, event, socket) do
    send_to_sidebar(event)
    send_to_chats(socket, agent_id, event)
    socket |> assign(:streaming, true) |> assign(:waiting, false)
  end

  @spec do_turn_end(String.t(), tuple(), Phoenix.LiveView.Socket.t()) ::
          Phoenix.LiveView.Socket.t()
  defp do_turn_end(agent_id, event, socket) do
    send_to_sidebar(event)
    send_to_chats(socket, agent_id, event)
    socket |> assign(:streaming, false) |> assign(:waiting, false)
  end

  @spec do_prompt_submit(String.t(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp do_prompt_submit(text, socket) do
    session_id = socket.assigns.active_session

    send_update(ChatComponent,
      id: "chat-main",
      action: :event,
      event: {:agent_event, :user_message, %{text: text, agent_id: nil}}
    )

    if session_id, do: Headless.prompt(session_id, text)

    assign(socket, :waiting, true)
  end

  @spec do_abort(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp do_abort(socket) do
    abort_agent(socket.assigns.orchestrator_id)

    send_update(ChatComponent,
      id: "chat-main",
      action: :event,
      event: {:agent_event, :aborted, %{}}
    )

    assign(socket, streaming: false, waiting: false)
  end

  @spec do_abort_all(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp do_abort_all(socket) do
    Enum.each(socket.assigns.agent_order, &abort_agent/1)

    send_update(ChatComponent,
      id: "chat-main",
      action: :event,
      event: {:agent_event, :aborted, %{}}
    )

    assign(socket, streaming: false, waiting: false)
  end

  @spec do_delete_session(String.t(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp do_delete_session(session_id, socket) do
    Headless.delete_session(session_id)
    sessions = Headless.list_sessions()

    if socket.assigns.active_session == session_id do
      next_session_after_delete(socket, sessions)
    else
      assign(socket, :sessions, sessions)
    end
  end

  @spec do_open_agent(String.t(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp do_open_agent(agent_id, socket) do
    send_update(ChatComponent,
      id: "chat-overlay",
      action: :load,
      session_id: socket.assigns.active_session,
      perspective_agent_id: agent_id,
      agents: socket.assigns.agents
    )

    assign(socket, :overlay, agent_id)
  end

  @spec do_resend_message(non_neg_integer(), String.t(), Phoenix.LiveView.Socket.t()) ::
          Phoenix.LiveView.Socket.t()
  defp do_resend_message(db_id, text, socket) do
    session_id = socket.assigns.active_session

    if session_id do
      # rewind_to_message returns only after both the truncation and the new
      # prompt call have been processed by the agent, so the session is in the
      # correct state when we reload the component.
      Headless.rewind_to_message(session_id, db_id, text)

      send_update(ChatComponent,
        id: "chat-main",
        action: :load,
        session_id: session_id,
        perspective_agent_id: nil,
        agents: socket.assigns.agents
      )
    end

    socket
    |> assign(:edit_message, nil)
    |> assign(:waiting, true)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec find_initial_session([map()]) :: {:ok, String.t()} | {:error, term()}
  defp find_initial_session(sessions) do
    case Enum.find(sessions, & &1.active) || List.first(sessions) do
      nil ->
        Headless.start_session()

      %{active: true, session_id: id} ->
        {:ok, id}

      %{session_id: id} ->
        case Headless.resume_session(id) do
          {:ok, _} = ok -> ok
          {:error, _} -> Headless.start_session()
        end
    end
  end

  @spec next_session_after_delete(Phoenix.LiveView.Socket.t(), [map()]) ::
          Phoenix.LiveView.Socket.t()
  defp next_session_after_delete(socket, sessions) do
    case List.first(sessions) do
      nil ->
        case Headless.start_session() do
          {:ok, sid} -> socket |> load_session(sid) |> assign(:sessions, Headless.list_sessions())
          {:error, _} -> assign(socket, :sessions, sessions)
        end

      %{session_id: sid, active: true} ->
        socket |> load_session(sid) |> assign(:sessions, sessions)

      %{session_id: sid} ->
        case Headless.resume_session(sid) do
          {:ok, resumed_id} ->
            socket |> load_session(resumed_id) |> assign(:sessions, Headless.list_sessions())

          {:error, _} ->
            assign(socket, :sessions, sessions)
        end
    end
  end

  @spec build_agent_entry({pid(), map()}, {map(), [String.t()], String.t() | nil}) ::
          {map(), [String.t()], String.t() | nil}
  defp build_agent_entry({pid, meta}, {acc, ord, orch}) do
    state = Agent.get_state(pid)
    {model_cost, model_id, context_window} = agent_model_info(state)
    color_index = length(ord)

    entry = %{
      id: meta.id,
      name: meta.name || meta.type,
      type: meta.type,
      model: model_id,
      status: state.status,
      usage: state.usage || %{input_tokens: 0, output_tokens: 0},
      cost: Map.get(state, :cost, 0.0),
      model_cost: model_cost,
      context_window: context_window,
      context_tokens: load_context_tokens(state.session_id, meta.id),
      color_index: color_index
    }

    new_orch = if meta.type == "orchestrator", do: meta.id, else: orch
    {Map.put(acc, meta.id, entry), ord ++ [meta.id], new_orch}
  end

  @spec load_context_tokens(String.t() | nil, String.t()) :: non_neg_integer()
  defp load_context_tokens(nil, _agent_id), do: 0

  defp load_context_tokens(session_id, agent_id) do
    case Session.messages(session_id, agent_id: agent_id) do
      {:ok, rows} -> rows |> Enum.map(& &1.message) |> Message.estimate_tokens()
      _ -> 0
    end
  end

  @spec agent_model_info(map()) :: {map(), String.t(), pos_integer()}
  defp agent_model_info(%{
         model: %Planck.AI.Model{cost: cost, name: name, id: id, context_window: cw}
       }) do
    {cost, name || id, cw}
  end

  defp agent_model_info(_), do: {%{input: 0.0, output: 0.0}, "unknown", 4_096}

  @spec load_session(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  defp load_session(socket, session_id) do
    if prev = socket.assigns[:active_session] do
      Phoenix.PubSub.unsubscribe(Planck.Agent.PubSub, "session:#{prev}")
    end

    Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "session:#{session_id}")

    {agents, agent_order, orchestrator_id} = load_agents(session_id)
    session_name = get_session_name(session_id)
    sidecar_status = SidecarManager.status() |> map_sidecar_status()
    initial_usage = derive_total_usage(agents)

    send_update(AgentsSidebar,
      id: "agents-sidebar",
      action: :load,
      agents: agents,
      agent_order: agent_order,
      sidecar: sidecar_status
    )

    send_update(StatusBar,
      id: "status-bar",
      action: :load,
      usage: initial_usage,
      sidecar: sidecar_status
    )

    {description, welcome} = session_description(session_id)

    send_update(ChatComponent,
      id: "chat-main",
      action: :load,
      session_id: session_id,
      perspective_agent_id: nil,
      agents: agents,
      description: description,
      welcome: welcome
    )

    socket
    |> assign(:active_session, session_id)
    |> assign(:session_name, session_name)
    |> assign(:agents, agents)
    |> assign(:agent_order, agent_order)
    |> assign(:orchestrator_id, orchestrator_id)
    |> assign(:streaming, false)
    |> assign(:waiting, false)
  end

  @spec load_agents(String.t()) :: {%{String.t() => map()}, [String.t()], String.t() | nil}
  defp load_agents(session_id) do
    case Session.get_metadata(session_id) do
      {:ok, %{"team_id" => team_id}} when not is_nil(team_id) ->
        members = Registry.lookup(Planck.Agent.Registry, {team_id, :member})

        {agents, order, orch_id} =
          Enum.reduce(members, {%{}, [], nil}, &build_agent_entry/2)

        {agents, order, orch_id}

      _ ->
        {%{}, [], nil}
    end
  end

  @spec get_session_name(String.t()) :: String.t() | nil
  defp get_session_name(session_id) do
    case Session.get_metadata(session_id) do
      {:ok, %{"session_name" => name}} -> name
      _ -> nil
    end
  end

  @spec session_description(String.t()) :: {String.t() | nil, boolean()}
  defp session_description(session_id) do
    case Session.get_metadata(session_id) do
      {:ok, meta} ->
        cond do
          meta["team_alias"] in [nil, ""] ->
            {nil, true}

          is_binary(meta["team_description"]) and meta["team_description"] != "" ->
            {meta["team_description"], false}

          true ->
            {nil, false}
        end

      _ ->
        {nil, false}
    end
  end

  @spec map_sidecar_status(atom()) :: :idle | :building | :starting | :connected | :failed
  defp map_sidecar_status(:connected), do: :connected
  defp map_sidecar_status(:building), do: :building
  defp map_sidecar_status(:starting), do: :starting
  defp map_sidecar_status(:failed), do: :failed
  defp map_sidecar_status(_), do: :idle

  @inter_agent_tools ~w(ask_agent delegate_task send_response interrupt_agent)

  @spec abort_agent(String.t() | nil) :: :ok
  defp abort_agent(nil), do: :ok

  defp abort_agent(agent_id) do
    case Planck.Agent.whereis(agent_id) do
      {:ok, pid} -> Planck.Agent.abort(pid)
      _ -> :ok
    end

    :ok
  end

  @spec send_to_chats(Phoenix.LiveView.Socket.t(), nil | String.t(), tuple()) :: :ok
  defp send_to_chats(socket, agent_id, event)

  defp send_to_chats(socket, nil, event) do
    send_update(ChatComponent, id: "chat-main", action: :event, event: event)

    if socket.assigns.overlay do
      send_update(ChatComponent, id: "chat-overlay", action: :event, event: event)
    end

    :ok
  end

  defp send_to_chats(socket, agent_id, event) when is_binary(agent_id) do
    if agent_id == socket.assigns.orchestrator_id do
      send_update(ChatComponent, id: "chat-main", action: :event, event: event)
      maybe_route_delegation_to_overlay(socket, event)
    end

    # Only route to the overlay for workers — the orchestrator's view is already
    # covered by chat-main (full session), so routing to both would show the
    # same streaming text twice.
    if socket.assigns.overlay == agent_id and agent_id != socket.assigns.orchestrator_id do
      send_update(ChatComponent, id: "chat-overlay", action: :event, event: event)
    end

    :ok
  end

  # When the orchestrator uses ask_agent/delegate_task, route it to the overlay
  # as an incoming message if the target agent is currently being viewed.
  @spec maybe_route_delegation_to_overlay(Phoenix.LiveView.Socket.t(), tuple()) :: :ok
  defp maybe_route_delegation_to_overlay(
         socket,
         {:agent_event, :tool_start, %{name: name, args: args, agent_id: sender_id}}
       )
       when name in @inter_agent_tools do
    overlay = socket.assigns.overlay

    if overlay do
      worker = Map.get(socket.assigns.agents, overlay, %{})

      if targets_overlay?(args, worker) do
        sender = Map.get(socket.assigns.agents, sender_id, %{})
        sender_name = sender[:name] || sender[:type] || "agent"
        text = args["question"] || args["task"] || ""

        send_update(ChatComponent,
          id: "chat-overlay",
          action: :event,
          event:
            {:agent_event, :inter_agent_in,
             %{text: text, tool_name: name, agent_name: sender_name, agent_id: sender_id}}
        )
      end
    end

    :ok
  end

  defp maybe_route_delegation_to_overlay(_socket, _event), do: :ok

  @spec targets_overlay?(map(), map()) :: boolean()
  defp targets_overlay?(args, worker) do
    (worker[:type] && args["type"] == worker[:type]) ||
      (worker[:name] && args["name"] == worker[:name])
  end

  @spec send_to_sidebar(tuple()) :: :ok
  defp send_to_sidebar(event) do
    send_update(AgentsSidebar, id: "agents-sidebar", action: :event, event: event)
  end

  @spec send_to_status_bar(tuple()) :: :ok
  defp send_to_status_bar(event) do
    send_update(StatusBar, id: "status-bar", action: :event, event: event)
  end

  @spec derive_total_usage(%{String.t() => map()}) ::
          %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer(), cost: float()}
  defp derive_total_usage(agents) do
    Enum.reduce(agents, %{input_tokens: 0, output_tokens: 0, cost: 0.0}, fn {_id, agent}, acc ->
      %{
        input_tokens: acc.input_tokens + agent.usage.input_tokens,
        output_tokens: acc.output_tokens + agent.usage.output_tokens,
        cost: acc.cost + agent.cost
      }
    end)
  end
end
