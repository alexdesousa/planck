defmodule Planck.Web.SessionLive do
  use Planck.Web, :live_view

  import Planck.Web.Components

  alias Planck.Agent
  alias Planck.Agent.Session
  alias Planck.Headless
  alias Planck.Headless.SidecarManager
  alias Planck.Web.Live.{ChatComponent, PromptInput}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:sessions, [])
      |> assign(:active_session, nil)
      |> assign(:session_name, nil)
      |> assign(:agents, %{})
      |> assign(:agent_order, [])
      |> assign(:orchestrator_id, nil)
      |> assign(:usage, %{input_tokens: 0, output_tokens: 0, cost: 0.0})
      |> assign(:sidecar, :idle)
      |> assign(:overlay, nil)
      |> assign(:streaming, false)
      |> assign(:waiting, false)
      |> assign(:left_open, false)
      |> assign(:right_open, false)
      |> assign(:edit_message, nil)
      |> assign(:show_new_session, false)
      |> assign(:teams, [])

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "planck:sidecar")

      sessions = Headless.list_sessions()
      active = Enum.find(sessions, & &1.active) || List.first(sessions)

      socket =
        cond do
          active && active.active ->
            load_session(socket, active.session_id)

          active ->
            case Headless.resume_session(active.session_id) do
              {:ok, session_id} ->
                load_session(socket, session_id)

              {:error, _} ->
                case Headless.start_session() do
                  {:ok, session_id} -> load_session(socket, session_id)
                  {:error, _} -> socket
                end
            end

          true ->
            case Headless.start_session() do
              {:ok, session_id} -> load_session(socket, session_id)
              {:error, _} -> socket
            end
        end

      teams = Planck.Headless.ResourceStore.get().teams |> Map.keys() |> Enum.sort()

      {:ok,
       socket
       |> assign(:sessions, Headless.list_sessions())
       |> assign(:teams, teams)}
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
    socket = socket |> assign(:waiting, false) |> assign(:streaming, true)
    socket = update_agent_status(socket, agent_id, :streaming)
    send_to_chats(socket, agent_id, event)
    {:noreply, socket}
  end

  def handle_info({:agent_event, :turn_end, %{usage: usage, agent_id: agent_id}} = event, socket) do
    model_cost =
      get_in(socket.assigns.agents, [agent_id, :model_cost]) || %{input: 0.0, output: 0.0}

    socket =
      socket
      |> update_agent_status(agent_id, :idle)
      |> update_agent_usage(agent_id, usage, model_cost)
      |> update_total_usage(usage, model_cost)
      |> assign(:streaming, false)
      |> assign(:waiting, false)

    send_to_chats(socket, agent_id, event)
    {:noreply, socket}
  end

  def handle_info({:agent_event, :text_delta, %{agent_id: agent_id}} = event, socket) do
    socket = assign(socket, :streaming, true)
    send_to_chats(socket, agent_id, event)
    {:noreply, socket}
  end

  def handle_info({:agent_event, :thinking_delta, %{agent_id: agent_id}} = event, socket) do
    socket = assign(socket, :streaming, true)
    send_to_chats(socket, agent_id, event)
    {:noreply, socket}
  end

  def handle_info({:agent_event, :tool_start, %{agent_id: agent_id}} = event, socket) do
    send_to_chats(socket, agent_id, event)
    {:noreply, socket}
  end

  def handle_info({:agent_event, :tool_end, _payload} = event, socket) do
    # tool_end doesn't carry agent_id — broadcast to all open chats
    send_update(ChatComponent, id: "chat-main", action: :event, event: event)

    if socket.assigns.overlay do
      send_update(ChatComponent, id: "chat-overlay", action: :event, event: event)
    end

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

  def handle_info({:agent_event, _type, _payload}, socket) do
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # PubSub events — sidecar
  # ---------------------------------------------------------------------------

  def handle_info({:building, _dir}, socket) do
    {:noreply, assign(socket, :sidecar, :building)}
  end

  def handle_info({:starting, _dir}, socket) do
    {:noreply, assign(socket, :sidecar, :starting)}
  end

  def handle_info({:connected, _node}, socket) do
    {:noreply, assign(socket, :sidecar, :connected)}
  end

  def handle_info({:disconnected, _node}, socket) do
    {:noreply, assign(socket, :sidecar, :idle)}
  end

  def handle_info({:exited, _reason}, socket) do
    {:noreply, assign(socket, :sidecar, :failed)}
  end

  def handle_info({:error, _step, _reason}, socket) do
    {:noreply, assign(socket, :sidecar, :failed)}
  end

  # ---------------------------------------------------------------------------
  # User events
  # ---------------------------------------------------------------------------

  def handle_info({:prompt_submit, text}, socket) when byte_size(text) > 0 do
    session_id = socket.assigns.active_session

    user_event = {:agent_event, :user_message, %{text: text, agent_id: nil}}
    send_update(ChatComponent, id: "chat-main", action: :event, event: user_event)

    socket = assign(socket, :waiting, true)

    if session_id, do: Headless.prompt(session_id, text)

    {:noreply, socket}
  end

  def handle_info(:prompt_abort, socket) do
    {:noreply, handle_event("abort", %{}, socket) |> elem(1)}
  end

  def handle_info(:prompt_abort_all, socket) do
    {:noreply, handle_event("abort_all", %{}, socket) |> elem(1)}
  end

  def handle_info({:open_edit_message, %{db_id: db_id, text: text}}, socket) do
    {:noreply, assign(socket, :edit_message, %{db_id: db_id, text: text})}
  end

  def handle_info(:close_edit_modal, socket) do
    {:noreply, assign(socket, :edit_message, nil)}
  end

  def handle_info({:resend_message, %{db_id: db_id, text: text}}, socket) do
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
        perspective_agent_id: socket.assigns[:perspective_agent_id],
        agents: socket.assigns[:agents]
      )
    end

    {:noreply, socket |> assign(:edit_message, nil) |> assign(:waiting, true)}
  end

  @impl true
  def handle_event(event, params, socket)

  def handle_event("open_agent", %{"id" => agent_id}, socket) do
    send_update(ChatComponent,
      id: "chat-overlay",
      action: :load,
      session_id: socket.assigns.active_session,
      perspective_agent_id: agent_id,
      agents: socket.assigns.agents
    )

    {:noreply, assign(socket, :overlay, agent_id)}
  end

  def handle_event("abort", _params, socket) do
    abort_agent(socket.assigns.orchestrator_id)

    send_update(ChatComponent,
      id: "chat-main",
      action: :event,
      event: {:agent_event, :aborted, %{}}
    )

    {:noreply, assign(socket, streaming: false, waiting: false)}
  end

  def handle_event("abort_all", _params, socket) do
    socket.assigns.agent_order
    |> Enum.each(fn agent_id ->
      abort_agent(agent_id)
    end)

    send_update(ChatComponent,
      id: "chat-main",
      action: :event,
      event: {:agent_event, :aborted, %{}}
    )

    {:noreply, assign(socket, streaming: false, waiting: false)}
  end

  def handle_event("close_overlay", _params, socket) do
    {:noreply, assign(socket, :overlay, nil)}
  end

  def handle_event("delete_session", %{"id" => session_id}, socket) do
    Headless.delete_session(session_id)

    sessions = Headless.list_sessions()

    # If we deleted the active session, switch to the next one or create a new one
    socket =
      if socket.assigns.active_session == session_id do
        case List.first(sessions) do
          nil ->
            case Headless.start_session() do
              {:ok, sid} ->
                socket |> load_session(sid) |> assign(:sessions, Headless.list_sessions())

              {:error, _} ->
                assign(socket, :sessions, sessions)
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
      else
        assign(socket, :sessions, sessions)
      end

    {:noreply, socket}
  end

  def handle_event("new_session", _params, socket) do
    {:noreply, assign(socket, show_new_session: true, left_open: false)}
  end

  def handle_event("close_new_session", _params, socket) do
    {:noreply, assign(socket, :show_new_session, false)}
  end

  def handle_event("create_session", %{"team" => team, "name" => name}, socket) do
    opts =
      []
      |> then(fn o -> if team != "", do: Keyword.put(o, :template, team), else: o end)
      |> then(fn o -> if name != "", do: Keyword.put(o, :name, name), else: o end)

    case Headless.start_session(opts) do
      {:ok, session_id} ->
        {:noreply,
         socket
         |> load_session(session_id)
         |> assign(:sessions, Headless.list_sessions())
         |> assign(:show_new_session, false)}

      {:error, _} ->
        {:noreply, assign(socket, :show_new_session, false)}
    end
  end

  def handle_event("switch_session", %{"id" => session_id}, socket) do
    active_ids = socket.assigns.sessions |> Enum.filter(& &1.active) |> Enum.map(& &1.session_id)

    result =
      if session_id in active_ids do
        {:ok, session_id}
      else
        Headless.resume_session(session_id)
      end

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
  # Private
  # ---------------------------------------------------------------------------

  @spec load_session(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  defp load_session(socket, session_id) do
    Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "session:#{session_id}")

    {agents, agent_order, orchestrator_id} = load_agents(session_id)
    session_name = get_session_name(session_id)
    sidecar_status = SidecarManager.status() |> map_sidecar_status()

    socket =
      socket
      |> assign(:active_session, session_id)
      |> assign(:session_name, session_name)
      |> assign(:agents, agents)
      |> assign(:agent_order, agent_order)
      |> assign(:orchestrator_id, orchestrator_id)
      |> assign(:sidecar, sidecar_status)
      |> assign(:waiting, false)
      |> assign(:streaming, false)

    # Load main chat from session
    # Main chat shows all session messages — no perspective filtering.
    # Perspective filtering is only used in the overlay (single agent view).
    send_update(ChatComponent,
      id: "chat-main",
      action: :load,
      session_id: session_id,
      perspective_agent_id: nil,
      agents: agents
    )

    socket
  end

  @spec load_agents(String.t()) :: {%{String.t() => map()}, [String.t()], String.t() | nil}
  defp load_agents(session_id) do
    case Session.get_metadata(session_id) do
      {:ok, %{"team_id" => team_id}} when not is_nil(team_id) ->
        members = Registry.lookup(Planck.Agent.Registry, {team_id, :member})

        {agents, order, orch_id} =
          Enum.reduce(members, {%{}, [], nil}, fn {pid, meta}, {acc, ord, orch} ->
            info = Agent.get_info(pid)

            {model_cost, model_id} =
              case Agent.get_state(pid) do
                %{model: %Planck.AI.Model{cost: cost, name: name, id: id}} ->
                  {cost, name || id}

                _ ->
                  {%{input: 0.0, output: 0.0}, "unknown"}
              end

            color_index = length(ord)
            is_orchestrator = meta.type == "orchestrator"

            entry = %{
              id: meta.id,
              name: meta.name || meta.type,
              type: meta.type,
              model: model_id,
              status: info.status,
              usage: info.usage || %{input_tokens: 0, output_tokens: 0},
              cost: 0.0,
              model_cost: model_cost,
              color_index: color_index
            }

            new_orch = if is_orchestrator, do: meta.id, else: orch
            {Map.put(acc, meta.id, entry), ord ++ [meta.id], new_orch}
          end)

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

  @spec send_to_chats(Phoenix.LiveView.Socket.t(), String.t(), tuple()) :: :ok
  defp send_to_chats(socket, agent_id, event) do
    if agent_id == socket.assigns.orchestrator_id do
      send_update(ChatComponent, id: "chat-main", action: :event, event: event)
      maybe_route_delegation_to_overlay(socket, event)
    end

    if socket.assigns.overlay == agent_id do
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

  @spec update_agent_status(Phoenix.LiveView.Socket.t(), String.t(), atom()) ::
          Phoenix.LiveView.Socket.t()
  defp update_agent_status(socket, agent_id, status) do
    update(socket, :agents, fn agents ->
      case Map.fetch(agents, agent_id) do
        {:ok, agent} -> Map.put(agents, agent_id, %{agent | status: status})
        :error -> agents
      end
    end)
  end

  @spec update_agent_usage(Phoenix.LiveView.Socket.t(), String.t(), map(), map()) ::
          Phoenix.LiveView.Socket.t()
  defp update_agent_usage(socket, agent_id, usage, model_cost) do
    update(socket, :agents, fn agents ->
      case Map.fetch(agents, agent_id) do
        {:ok, agent} ->
          cost = calculate_cost(usage, model_cost)
          Map.put(agents, agent_id, %{agent | usage: usage, cost: agent.cost + cost})

        :error ->
          agents
      end
    end)
  end

  @spec update_total_usage(Phoenix.LiveView.Socket.t(), map(), map()) ::
          Phoenix.LiveView.Socket.t()
  defp update_total_usage(socket, %{input_tokens: i, output_tokens: o}, model_cost) do
    cost = calculate_cost(%{input_tokens: i, output_tokens: o}, model_cost)

    update(socket, :usage, fn u ->
      %{input_tokens: u.input_tokens + i, output_tokens: u.output_tokens + o, cost: u.cost + cost}
    end)
  end

  defp update_total_usage(socket, _, _), do: socket

  @spec calculate_cost(map(), map()) :: float()
  defp calculate_cost(%{input_tokens: i, output_tokens: o}, %{input: in_rate, output: out_rate}) do
    (i * in_rate + o * out_rate) / 1_000_000
  end

  defp calculate_cost(_, _), do: 0.0
end
