defmodule Planck.Web.SessionLive do
  use Planck.Web, :live_view

  import Planck.Web.Components

  alias Planck.Agent
  alias Planck.Agent.Session
  alias Planck.Headless
  alias Planck.Headless.SidecarManager

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:sessions, [])
      |> assign(:active_session, nil)
      |> assign(:session_name, nil)
      |> assign(:messages, [])
      |> assign(:agents, %{})
      |> assign(:agent_order, [])
      |> assign(:usage, %{input: 0, output: 0, cost: 0.0})
      |> assign(:sidecar, :idle)
      |> assign(:overlay, nil)
      |> assign(:prompt, "")
      |> assign(:streaming, false)
      |> assign(:left_open, false)
      |> assign(:right_open, false)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "planck:sidecar")

      sessions = Headless.list_sessions()
      active = Enum.find(sessions, & &1.active) || List.first(sessions)

      socket =
        if active do
          load_session(socket, active.session_id)
        else
          case Headless.start_session() do
            {:ok, session_id} -> load_session(socket, session_id)
            {:error, _} -> socket
          end
        end

      {:ok, assign(socket, :sessions, Headless.list_sessions())}
    else
      {:ok, socket}
    end
  end


  # ---------------------------------------------------------------------------
  # PubSub events — agent
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:agent_event, :turn_start, %{agent_id: agent_id}}, socket) do
    {:noreply, update_agent_status(socket, agent_id, :streaming)}
  end

  def handle_info({:agent_event, :turn_end, %{usage: usage, agent_id: agent_id}}, socket) do
    model_cost = get_in(socket.assigns.agents, [agent_id, :model_cost]) || %{input: 0.0, output: 0.0}

    socket =
      socket
      |> update_agent_status(agent_id, :idle)
      |> update_agent_usage(agent_id, usage, model_cost)
      |> update_total_usage(usage, model_cost)
      |> assign(:streaming, false)

    {:noreply, socket}
  end

  def handle_info({:agent_event, :text_delta, %{text: text, agent_id: agent_id}}, socket) do
    socket =
      socket
      |> assign(:streaming, true)
      |> append_streaming_delta(agent_id, text)

    {:noreply, socket}
  end

  def handle_info({:agent_event, :thinking_delta, %{text: text, agent_id: agent_id}}, socket) do
    socket =
      socket
      |> assign(:streaming, true)
      |> append_thinking_delta(agent_id, text)

    {:noreply, socket}
  end

  def handle_info({:agent_event, :tool_start, %{id: id, name: name, args: args, agent_id: agent_id}}, socket) do
    entry = %{
      id: "tool-#{id}",
      type: :tool,
      agent_id: agent_id,
      tool_id: id,
      tool_name: name,
      tool_args: args,
      tool_result: nil,
      tool_error: false,
      expanded: false
    }

    {:noreply, update(socket, :messages, &(&1 ++ [entry]))}
  end

  def handle_info({:agent_event, :tool_end, %{id: id, result: result, error: error}}, socket) do
    messages =
      Enum.map(socket.assigns.messages, fn
        %{tool_id: ^id} = m -> %{m | tool_result: inspect(result), tool_error: error}
        m -> m
      end)

    {:noreply, assign(socket, :messages, messages)}
  end

  def handle_info({:agent_event, :usage_delta, _payload}, socket), do: {:noreply, socket}
  def handle_info({:agent_event, _type, _payload}, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # PubSub events — sidecar
  # ---------------------------------------------------------------------------

  def handle_info({:building, _dir}, socket), do: {:noreply, assign(socket, :sidecar, :building)}
  def handle_info({:starting, _dir}, socket), do: {:noreply, assign(socket, :sidecar, :starting)}
  def handle_info({:connected, _node}, socket), do: {:noreply, assign(socket, :sidecar, :connected)}
  def handle_info({:disconnected, _node}, socket), do: {:noreply, assign(socket, :sidecar, :idle)}
  def handle_info({:exited, _reason}, socket), do: {:noreply, assign(socket, :sidecar, :failed)}
  def handle_info({:error, _step, _reason}, socket), do: {:noreply, assign(socket, :sidecar, :failed)}

  # ---------------------------------------------------------------------------
  # User events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("prompt_submit", %{"prompt" => text}, socket) when byte_size(text) > 0 do
    session_id = socket.assigns.active_session

    user_entry = %{
      id: "user-#{:erlang.unique_integer([:positive])}",
      type: :user,
      agent_id: nil,
      text: text,
      streaming: false
    }

    socket =
      socket
      |> update(:messages, &(&1 ++ [user_entry]))
      |> assign(:prompt, "")

    if session_id, do: Headless.prompt(session_id, text)

    {:noreply, socket}
  end

  def handle_event("prompt_submit", _params, socket), do: {:noreply, socket}

  def handle_event("prompt_change", %{"prompt" => text}, socket) do
    {:noreply, assign(socket, :prompt, text)}
  end

  def handle_event("open_agent", %{"id" => agent_id}, socket) do
    {:noreply, assign(socket, :overlay, agent_id)}
  end

  def handle_event("close_overlay", _params, socket) do
    {:noreply, assign(socket, :overlay, nil)}
  end

  def handle_event("new_session", _params, socket) do
    case Headless.start_session() do
      {:ok, session_id} ->
        {:noreply, socket |> load_session(session_id) |> assign(:sessions, Headless.list_sessions())}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("switch_session", %{"id" => session_id}, socket) do
    {:noreply,
     socket
     |> load_session(session_id)
     |> assign(:sessions, Headless.list_sessions())
     |> assign(:left_open, false)}
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

  def handle_event("toggle_thinking", %{"id" => entry_id}, socket) do
    messages =
      Enum.map(socket.assigns.messages, fn
        %{id: ^entry_id} = m -> %{m | expanded: !m.expanded}
        m -> m
      end)

    {:noreply, assign(socket, :messages, messages)}
  end

  def handle_event("toggle_tool", %{"id" => entry_id}, socket) do
    messages =
      Enum.map(socket.assigns.messages, fn
        %{id: ^entry_id} = m -> %{m | expanded: !m.expanded}
        m -> m
      end)

    {:noreply, assign(socket, :messages, messages)}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec load_session(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  defp load_session(socket, session_id) do
    Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "session:#{session_id}")

    messages =
      case Session.messages(session_id) do
        {:ok, rows} -> Enum.map(rows, &message_to_entry/1)
        _ -> []
      end

    {agents, agent_order} = load_agents(session_id)
    session_name = get_session_name(session_id)
    sidecar_status = SidecarManager.status() |> map_sidecar_status()

    socket
    |> assign(:active_session, session_id)
    |> assign(:session_name, session_name)
    |> assign(:messages, messages)
    |> assign(:agents, agents)
    |> assign(:agent_order, agent_order)
    |> assign(:sidecar, sidecar_status)
  end

  @spec load_agents(String.t()) :: {%{String.t() => map()}, [String.t()]}
  defp load_agents(session_id) do
    case Session.get_metadata(session_id) do
      {:ok, %{"team_id" => team_id}} when not is_nil(team_id) ->
        members = Registry.lookup(Planck.Agent.Registry, {team_id, :member})

        {agents, order} =
          Enum.reduce(members, {%{}, []}, fn {pid, meta}, {acc, ord} ->
            info = Agent.get_info(pid)
            state = Agent.get_state(pid)
            model_cost = get_in(state, [:model, :cost]) || %{input: 0.0, output: 0.0}
            color_index = length(ord)

            entry = %{
              id: meta.id,
              name: meta.name || meta.type,
              type: meta.type,
              status: info.status,
              usage: info.usage || %{input: 0, output: 0},
              cost: 0.0,
              model_cost: model_cost,
              color_index: color_index
            }

            {Map.put(acc, meta.id, entry), ord ++ [meta.id]}
          end)

        {agents, order}

      _ ->
        {%{}, []}
    end
  end

  @spec get_session_name(String.t()) :: String.t() | nil
  defp get_session_name(session_id) do
    case Session.get_metadata(session_id) do
      {:ok, %{"session_name" => name}} -> name
      _ -> nil
    end
  end

  @spec agent_label(%{String.t() => map()}, String.t() | nil) :: String.t()
  defp agent_label(agents, agent_id) do
    case Map.get(agents, agent_id) do
      nil -> agent_id || "agent"
      agent -> agent.name || agent.type || "agent"
    end
  end

  @spec map_sidecar_status(atom()) :: :idle | :building | :starting | :connected | :failed
  defp map_sidecar_status(:connected), do: :connected
  defp map_sidecar_status(:building), do: :building
  defp map_sidecar_status(:starting), do: :starting
  defp map_sidecar_status(:failed), do: :failed
  defp map_sidecar_status(_), do: :idle

  @spec message_to_entry(map()) :: map()
  defp message_to_entry(%{message: %{role: role, content: content}} = row) do
    %{
      id: "hist-#{:erlang.unique_integer([:positive])}",
      type: if(role == :user, do: :user, else: :assistant),
      agent_id: Map.get(row, :agent_id),
      text: extract_text_content(content),
      streaming: false
    }
  end

  defp message_to_entry(msg) do
    %{
      id: "hist-#{:erlang.unique_integer([:positive])}",
      type: :assistant,
      agent_id: nil,
      text: "",
      streaming: false
    }
    |> Map.merge(msg)
  end

  @spec extract_text_content(list() | term()) :: String.t()
  defp extract_text_content(content) when is_list(content) do
    content
    |> Enum.filter(&match?({:text, _}, &1))
    |> Enum.map_join("", fn {:text, t} -> t end)
  end

  defp extract_text_content(_), do: ""

  @spec update_agent_status(Phoenix.LiveView.Socket.t(), String.t(), atom()) :: Phoenix.LiveView.Socket.t()
  defp update_agent_status(socket, agent_id, status) do
    update(socket, :agents, fn agents ->
      case Map.fetch(agents, agent_id) do
        {:ok, agent} -> Map.put(agents, agent_id, %{agent | status: status})
        :error -> agents
      end
    end)
  end

  @spec update_agent_usage(Phoenix.LiveView.Socket.t(), String.t(), map(), map()) :: Phoenix.LiveView.Socket.t()
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

  @spec update_total_usage(Phoenix.LiveView.Socket.t(), map(), map()) :: Phoenix.LiveView.Socket.t()
  defp update_total_usage(socket, %{input: i, output: o} = _usage, model_cost) do
    cost = calculate_cost(%{input: i, output: o}, model_cost)

    update(socket, :usage, fn u ->
      %{input: u.input + i, output: u.output + o, cost: u.cost + cost}
    end)
  end

  defp update_total_usage(socket, _, _), do: socket

  @spec calculate_cost(map(), map()) :: float()
  defp calculate_cost(%{input: i, output: o}, %{input: in_rate, output: out_rate}) do
    (i * in_rate + o * out_rate) / 1_000_000
  end

  defp calculate_cost(_, _), do: 0.0

  @spec append_thinking_delta(Phoenix.LiveView.Socket.t(), String.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  defp append_thinking_delta(socket, agent_id, text) do
    messages = socket.assigns.messages

    case Enum.split_while(messages, fn m ->
           not (m.type == :thinking and m.agent_id == agent_id and m[:streaming])
         end) do
      {_before, []} ->
        entry = %{
          id: "think-#{agent_id}-#{:erlang.unique_integer([:positive])}",
          type: :thinking,
          agent_id: agent_id,
          text: text,
          streaming: true,
          expanded: false
        }

        update(socket, :messages, &(&1 ++ [entry]))

      {before, [current | rest]} ->
        updated = %{current | text: current.text <> text}
        assign(socket, :messages, before ++ [updated | rest])
    end
  end

  @spec append_streaming_delta(Phoenix.LiveView.Socket.t(), String.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  defp append_streaming_delta(socket, agent_id, text) do
    messages = socket.assigns.messages

    case Enum.split_while(messages, fn m ->
           not (m.type == :assistant and m.agent_id == agent_id and m[:streaming])
         end) do
      {_before, []} ->
        entry = %{
          id: "stream-#{agent_id}",
          type: :assistant,
          agent_id: agent_id,
          text: text,
          streaming: true
        }

        update(socket, :messages, &(&1 ++ [entry]))

      {before, [current | rest]} ->
        updated = %{current | text: current.text <> text}
        assign(socket, :messages, before ++ [updated | rest])
    end
  end
end
