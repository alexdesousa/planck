defmodule Planck.Web.Live.AgentDetails do
  @moduledoc """
  Read-only view of what an agent currently brings into context: its tools,
  active hooks, skills (and, for the orchestrator, slash commands), and the
  runtime-assembled system prompt.

  Rendered as the main content of the orchestrator info modal and inside the
  sliding details pane of the worker overlay. The worker pane passes
  `show_commands: false` — slash commands are user-triggered only and are
  not part of a worker's context.

  Each section is a collapsible card, collapsed by default.
  """

  use Planck.Web, :live_component

  @impl true
  def mount(socket)

  def mount(%Phoenix.LiveView.Socket{} = socket) do
    {:ok, toggle_collapsed(socket)}
  end

  @impl true
  def update(assigns, socket)

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:show_commands, fn -> true end)

    {:ok, socket}
  end

  @impl true
  def handle_event(event, params, socket)

  def handle_event("toggle_section", %{"section" => section}, %Phoenix.LiveView.Socket{} = socket) do
    {:noreply, toggle_collapsed(socket, [section])}
  end

  #############################################################################
  # Private helpers

  @spec toggle_collapsed(Phoenix.LiveView.Socket.t()) ::
          Phoenix.LiveView.Socket.t()
  @spec toggle_collapsed(Phoenix.LiveView.Socket.t(), [String.t()]) ::
          Phoenix.LiveView.Socket.t()
  defp toggle_collapsed(socket, toggles \\ [])

  defp toggle_collapsed(%Phoenix.LiveView.Socket{} = socket, []) do
    toggle_collapsed(socket, ["tools", "hooks", "skills", "commands"])
  end

  defp toggle_collapsed(%Phoenix.LiveView.Socket{} = socket, updates)
       when is_list(updates) do
    base = %{
      tools: false,
      hooks: false,
      skills: false,
      commands: false
    }

    collapsed =
      (socket.assigns[:collapsed] || base)
      |> Stream.map(fn {key, value} ->
        if to_string(key) in updates do
          {key, not value}
        else
          {key, value}
        end
      end)
      |> Map.new()

    assign(socket, :collapsed, collapsed)
  end

  #############################################################################
  # Private components

  attr :tools, :list, required: true
  attr :collapsed, :boolean, default: true
  attr :target, Phoenix.LiveComponent.CID

  defp tools_card(assigns) do
    ~H"""
    <.section_card
      id="tools"
      title={pgettext("agent details", "Tools")}
      count={length(@tools)}
      collapsed={@collapsed}
      target={@target}
    >
      <%= if @tools == [] do %>
        <p class="font-mono text-xs text-muted-foreground px-1 py-1">
          <%= pgettext("agent details", "None") %>
        </p>
      <% else %>
        <ul class="px-4 py-3 space-y-2.5">
          <li :for={tool <- @tools} class="flex gap-2">
            <span class="text-primary leading-5 text-xs">•</span>
            <div>
              <p class="font-mono text-xs font-bold"><%= tool.name %></p>
              <p class="text-xs text-muted-foreground"><%= tool.description %></p>
            </div>
          </li>
        </ul>
      <% end %>
    </.section_card>
    """
  end

  attr :hooks, :list, required: true
  attr :collapsed, :boolean, default: true
  attr :target, Phoenix.LiveComponent.CID

  defp hooks_card(assigns) do
    ~H"""
    <.section_card
      id="hooks"
      title={pgettext("agent details", "Hooks")}
      count={length(@hooks)}
      collapsed={@collapsed}
      target={@target}
    >
      <%= if @hooks == [] do %>
        <p class="font-mono text-xs text-muted-foreground px-1 py-1">
          <%= pgettext("agent details", "None") %>
        </p>
      <% else %>
        <ul class="px-4 py-3 space-y-2 font-mono text-xs">
          <li :for={hook <- @hooks} class="flex gap-2">
            <span class="text-primary leading-5 text-xs">•</span>
            <div class="flex flex-wrap gap-x-2">
              <span class="font-bold"><%= hook.kind %></span>
              <span class="text-muted-foreground">→</span>
              <span><%= hook.module %></span>
              <span :if={hook.node} class="text-muted-foreground">
                @ <%= hook.node %>
              </span>
            </div>
          </li>
        </ul>
      <% end %>
    </.section_card>
    """
  end

  attr :skills, :list, required: true
  attr :collapsed, :boolean, default: true
  attr :target, Phoenix.LiveComponent.CID

  defp skills_card(assigns) do
    ~H"""
    <.section_card
      id="skills"
      title={pgettext("agent details", "Skills")}
      count={length(@skills)}
      collapsed={@collapsed}
      target={@target}
    >
      <%= if @skills == [] do %>
        <p class="font-mono text-xs text-muted-foreground px-1 py-1">
          <%= pgettext("agent details", "None") %>
        </p>
      <% else %>
        <ul class="px-4 py-3 space-y-2.5 font-mono text-xs">
          <li :for={skill <- @skills} class="flex gap-2">
            <span class="text-primary leading-5 text-xs">•</span>
            <div>
              <p class="font-mono text-xs font-bold flex items-center gap-2">
                <%= skill.name %>
                <span
                  :if={skill.always_present}
                  class="border border-black px-1 text-[9px] uppercase text-muted-foreground"
                ><%= pgettext("badge", "always") %></span>
                <span
                  :if={!skill.always_present and skill.granted}
                  class="border border-black px-1 text-[9px] uppercase text-muted-foreground"
                ><%= pgettext("badge", "granted") %></span>
              </p>
              <p class="text-xs text-muted-foreground"><%= skill.description %></p>
            </div>
          </li>
        </ul>
      <% end %>
    </.section_card>
    """
  end

  attr :commands, :list, required: true
  attr :collapsed, :boolean, default: true
  attr :target, Phoenix.LiveComponent.CID

  defp commands_card(assigns) do
    ~H"""
    <.section_card
      id="commands"
      title={pgettext("agent details", "Commands")}
      count={length(@commands)}
      collapsed={@collapsed}
      target={@target}
    >
      <%= if @commands == [] do %>
        <p class="font-mono text-xs text-muted-foreground px-1 py-1">
          <%= pgettext("agent details", "None") %>
        </p>
      <% else %>
        <ul class="px-4 py-3 space-y-2.5 font-mono text-xs">
          <li :for={cmd <- @commands} class="flex gap-2">
            <span class="text-primary leading-5 text-xs">•</span>
            <div>
              <p class="font-mono text-xs font-bold flex items-center gap-2">
                /<%= cmd.name %>
                <span class="border border-black px-1 text-[9px] uppercase text-muted-foreground"><%= kind_label(cmd.kind) %></span>
              </p>
              <p class="text-xs text-muted-foreground"><%= cmd.description %></p>
            </div>
          </li>
        </ul>
      <% end %>
    </.section_card>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :count, :integer, default: 0
  attr :collapsed, :boolean, default: true
  attr :target, :any, default: nil
  slot :inner_block, required: true

  defp section_card(assigns) when is_map(assigns) do
    ~H"""
    <div class="border-2 border-black shadow-[4px_4px_0px_#000] bg-card">
      <button
        type="button"
        class="w-full flex items-center gap-2 px-3 py-2 font-mono text-xs font-bold
               hover:bg-muted/50 transition-colors"
        phx-click="toggle_section"
        phx-value-section={@id}
        phx-target={@target}
      >
        <span class="text-primary"><%= if @collapsed, do: "▶", else: "▼" %></span>
        <span><%= @title %></span>
        <span class="text-muted-foreground font-normal">({@count})</span>
      </button>
      <div class={[if(@collapsed, do: "hidden"), "border-t-2 border-border max-h-56 overflow-y-auto"]}>
        <%= render_slot(@inner_block) %>
      </div>
    </div>
    """
  end

  @spec kind_label(atom()) :: String.t()
  defp kind_label(type)

  defp kind_label(:builtin), do: pgettext("command kind", "builtin")
  defp kind_label(:command), do: pgettext("command kind", "command")
  defp kind_label(:skill), do: pgettext("command kind", "skill")
  defp kind_label(other), do: to_string(other)
end
