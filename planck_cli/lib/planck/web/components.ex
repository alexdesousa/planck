defmodule Planck.Web.Components do
  @moduledoc """
  NeoBrutalism function components for the Planck Web UI.

  All components follow the RetroUI purple design system: 2px black borders,
  offset box shadows, sharp corners, and the shared agent color palette.
  Import this module via `use Planck.Web, :live_view` or `:html`.
  """

  use Phoenix.Component

  # ---------------------------------------------------------------------------
  # Agent color palette — shared with TUI, assigned by spawn order.
  # Orchestrator always gets the neutral card; workers cycle through this list.
  # ---------------------------------------------------------------------------

  @agent_colors [
    %{bg: "#EA435F", text: "#ffffff"},
    %{bg: "#AAFC3D", text: "#000000"},
    %{bg: "#ffdb33", text: "#000000"},
    %{bg: "#C4A1FF", text: "#000000"},
    %{bg: "#F07200", text: "#ffffff"},
    %{bg: "#599D77", text: "#ffffff"},
    %{bg: "#5F4FE6", text: "#ffffff"},
    %{bg: "#FE91E9", text: "#000000"}
  ]

  @doc "Return the background and text color for a worker at the given spawn index."
  @spec agent_color(non_neg_integer()) :: %{bg: String.t(), text: String.t()}
  def agent_color(index) do
    Enum.at(@agent_colors, rem(index, length(@agent_colors)))
  end

  # ---------------------------------------------------------------------------
  # agent_card/1
  # ---------------------------------------------------------------------------

  @doc """
  Colored sidebar card for a worker agent.

  Displays name, type, token usage, and an active/idle status dot.
  Background color is drawn from the shared `@agent_colors` palette using
  `color_index` (spawn order, 0-based). Clicking the card fires `on_click`
  with `phx-value-id` set to the agent id.
  """
  attr :agent, :map, required: true
  attr :color_index, :integer, default: 0
  attr :on_click, :string, default: "open_agent"

  def agent_card(assigns) do
    color = agent_color(assigns.color_index)

    assigns =
      assigns
      |> assign(:bg, color.bg)
      |> assign(:text_color, color.text)

    ~H"""
    <div
      class="border-2 border-black p-3 cursor-pointer transition-all duration-100
             shadow-[4px_4px_0px_#000] hover:shadow-[6px_6px_0px_#000]
             hover:-translate-x-0.5 hover:-translate-y-0.5"
      style={"background-color: #{@bg}; color: #{@text_color};"}
      phx-click={@on_click}
      phx-value-id={@agent.id}
    >
      <div class="flex items-center justify-between gap-2">
        <span class="font-bold font-mono text-sm truncate"><%= @agent.name || @agent.type %></span>
        <span class={[
          "w-2.5 h-2.5 rounded-full border border-black flex-shrink-0",
          if(@agent.status == :streaming, do: "bg-white animate-pulse", else: "bg-white/30")
        ]} />
      </div>
      <p class="font-mono text-xs mt-1 opacity-75"><%= @agent.type %></p>
      <p class="font-mono text-xs opacity-75 truncate"><%= @agent[:model] %></p>
      <p class="font-mono text-xs opacity-60"><%= format_usage(@agent.usage) %></p>
      <p class="font-mono text-xs opacity-60"><%= format_cost(@agent[:cost]) %></p>
      <p class="font-mono text-xs opacity-60"><%= format_context(@agent[:context_tokens], @agent[:context_window]) %></p>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # orchestrator_card/1
  # ---------------------------------------------------------------------------

  @doc """
  Neutral sidebar card for the orchestrator agent.

  Uses a white background with a primary-color outline rather than a saturated
  fill, distinguishing the coordinator from active worker cards without
  competing visually with them.
  """
  attr :agent, :map, required: true

  def orchestrator_card(assigns) do
    ~H"""
    <div
      class="border-2 border-black p-3 bg-card"
      style="outline: 2px solid var(--primary); outline-offset: -2px;"
    >
      <div class="flex items-center justify-between gap-2">
        <span class="font-bold font-mono text-sm text-primary truncate">
          <%= @agent.name || "orchestrator" %>
        </span>
        <span
          class={[
            "w-2.5 h-2.5 rounded-full border border-black flex-shrink-0",
            if(@agent.status == :streaming, do: "animate-pulse", else: "bg-muted")
          ]}
          style={if @agent.status == :streaming, do: "background-color: var(--primary);", else: ""}
        />
      </div>
      <p class="font-mono text-xs mt-1 text-muted-foreground">orchestrator</p>
      <p class="font-mono text-xs text-muted-foreground truncate"><%= @agent[:model] %></p>
      <p class="font-mono text-xs text-muted-foreground"><%= format_usage(@agent.usage) %></p>
      <p class="font-mono text-xs text-muted-foreground"><%= format_cost(@agent[:cost]) %></p>
      <p class="font-mono text-xs text-muted-foreground"><%= format_context(@agent[:context_tokens], @agent[:context_window]) %></p>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # tool_block/1
  # ---------------------------------------------------------------------------

  @doc """
  Collapsible tool call block shown in the chat panel.

  Collapsed by default — shows tool name and status (running/done/error).
  Expanded state shows the JSON-formatted input args and raw output text,
  separated into labelled sections. Fires `toggle_tool` with the entry id.
  """
  attr :entry, :map, required: true

  def tool_block(assigns) do
    ~H"""
    <div class="border-2 border-border max-w-2xl my-2">
      <button
        class="w-full flex items-center gap-2 px-3 py-1.5 bg-muted
               hover:bg-muted/80 font-mono text-xs text-left"
        phx-click="toggle_tool"
        phx-value-id={@entry.id}
      >
        <span class="text-muted-foreground"><%= if @entry.expanded, do: "▼", else: "▶" %></span>
        <span class="font-bold text-foreground"><%= @entry.tool_name %></span>
        <span class="ml-auto">
          <%= cond do %>
            <% @entry.tool_error -> %>
              <span class="text-destructive font-bold">error</span>
            <% @entry.tool_result -> %>
              <span class="text-green-600">done</span>
            <% true -> %>
              <span class="text-muted-foreground animate-pulse">running…</span>
          <% end %>
        </span>
      </button>
      <%= if @entry.expanded do %>
        <div class="border-t-2 border-border divide-y-2 divide-border">
          <%= if @entry.tool_args && map_size(@entry.tool_args) > 0 do %>
            <div class="px-3 py-2">
              <p class="font-mono text-xs text-muted-foreground mb-1">input</p>
              <pre class="font-mono text-xs whitespace-pre-wrap overflow-x-auto text-foreground"><%= Jason.encode!(@entry.tool_args, pretty: true) %></pre>
            </div>
          <% end %>
          <%= if @entry.tool_result do %>
            <div class="px-3 py-2">
              <p class="font-mono text-xs text-muted-foreground mb-1">output</p>
              <pre class={[
                "font-mono text-xs whitespace-pre-wrap overflow-x-auto",
                if(@entry.tool_error, do: "text-destructive", else: "text-foreground")
              ]}><%= @entry.tool_result %></pre>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # thinking_block/1
  # ---------------------------------------------------------------------------

  @doc """
  Collapsible extended thinking block shown in the chat panel.

  Rendered with a dashed border to distinguish it from regular message content.
  Collapsed by default with a "thinking…" label. Fires `toggle_thinking` with
  the entry id. Only appears when a model with extended thinking is in use.
  """
  attr :entry, :map, required: true

  def thinking_block(assigns) do
    ~H"""
    <div class="border-2 border-dashed border-border max-w-2xl my-2">
      <button
        class="w-full flex items-center gap-2 px-3 py-1.5
               hover:bg-muted/50 font-mono text-xs text-left"
        phx-click="toggle_thinking"
        phx-value-id={@entry.id}
      >
        <span class="text-muted-foreground"><%= if @entry.expanded, do: "▼", else: "▶" %></span>
        <span class="text-muted-foreground italic">thinking…</span>
      </button>
      <%= if @entry.expanded do %>
        <div class="border-t-2 border-dashed border-border px-3 py-2">
          <p class="font-mono text-xs text-muted-foreground whitespace-pre-wrap leading-relaxed">
            <%= @entry.text %>
          </p>
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # sidecar_status/1
  # ---------------------------------------------------------------------------

  @doc """
  Inline sidecar connection indicator: colored dot + label.

  Reflects `SidecarManager` lifecycle states: `:idle`, `:building`,
  `:starting`, `:connected`, `:failed`.
  """
  attr :status, :atom, required: true

  def sidecar_status(assigns) do
    {dot_class, label} =
      case assigns.status do
        :connected -> {"bg-green-500", "sidecar"}
        :building -> {"bg-accent animate-pulse", "building…"}
        :starting -> {"bg-accent animate-pulse", "starting…"}
        :failed -> {"bg-destructive", "sidecar error"}
        _ -> {"bg-muted", "no sidecar"}
      end

    assigns = assign(assigns, dot_class: dot_class, label: label)

    ~H"""
    <span class="flex items-center gap-1">
      <span class={["w-1.5 h-1.5 rounded-full", @dot_class]} />
      <span><%= @label %></span>
    </span>
    """
  end

  # ---------------------------------------------------------------------------
  # new_session_modal/1
  # ---------------------------------------------------------------------------

  @doc """
  Modal dialog for creating a new session with an optional team and name.
  Fires `create_session` with `%{team: team_alias | "", name: name | ""}`.
  """
  attr :teams, :list, required: true

  def new_session_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/50">
      <div class="border-2 border-black bg-card shadow-[8px_8px_0px_#000] w-80">
        <div class="border-b-2 border-border px-4 py-2 flex items-center justify-between bg-card">
          <span class="font-bold font-mono text-sm">New Session</span>
          <button
            class="border-2 border-black px-3 py-1 font-mono text-xs font-bold
                   shadow-[2px_2px_0px_#000] hover:shadow-[4px_4px_0px_#000]
                   hover:-translate-x-0.5 hover:-translate-y-0.5 transition-all bg-card"
            phx-click="close_new_session"
          >✕</button>
        </div>
        <form phx-submit="create_session" class="p-4 space-y-3">
          <div>
            <label class="font-mono text-xs text-muted-foreground block mb-1">Team</label>
            <div class="border-2 border-black shadow-[2px_2px_0px_#000] divide-y-2 divide-black
                        max-h-40 overflow-y-auto">
              <label class="flex items-center gap-2 px-2 py-1.5 cursor-pointer font-mono text-sm
                             hover:bg-muted has-[:checked]:bg-muted">
                <input type="radio" name="team" value="" checked class="accent-black" />
                Dynamic (default)
              </label>
              <%= for team <- @teams do %>
                <label class="flex items-center gap-2 px-2 py-1.5 cursor-pointer font-mono text-sm
                               hover:bg-muted has-[:checked]:bg-muted">
                  <input type="radio" name="team" value={team} class="accent-black" />
                  <%= team %>
                </label>
              <% end %>
            </div>
          </div>
          <div>
            <label class="font-mono text-xs text-muted-foreground block mb-1">
              Name <span class="opacity-50">(optional)</span>
            </label>
            <input
              type="text"
              name="name"
              class="w-full border-2 border-black px-2 py-1.5 font-mono text-sm
                     bg-background focus:outline-none shadow-[2px_2px_0px_#000]
                     placeholder:text-muted-foreground"
              placeholder="my-session"
            />
          </div>
          <div class="flex justify-end gap-2 pt-1">
            <button
              type="button"
              class="border-2 border-black px-3 py-1 font-mono text-xs font-bold
                     shadow-[2px_2px_0px_#000] hover:shadow-[4px_4px_0px_#000]
                     hover:-translate-x-0.5 hover:-translate-y-0.5 transition-all bg-card"
              phx-click="close_new_session"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="border-2 border-black px-3 py-1 font-mono text-xs font-bold
                     shadow-[2px_2px_0px_#000] hover:shadow-[4px_4px_0px_#000]
                     hover:-translate-x-0.5 hover:-translate-y-0.5 transition-all
                     bg-primary text-primary-foreground"
            >
              Create
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # chat_message/1
  # ---------------------------------------------------------------------------

  @doc """
  A single chat message entry — user or assistant turn.

  Displays the sender label above the message text. Text content is extracted
  from the `Planck.Agent.Message` content list (`:text` parts only).
  """
  attr :message, :map, required: true
  attr :agent_name, :string, default: nil

  def chat_message(assigns) do
    ~H"""
    <div class="mb-4">
      <div class="font-mono text-xs text-muted-foreground mb-1">
        <%= if @message.role == :user, do: "you", else: @agent_name || "assistant" %>
      </div>
      <div class="text-sm leading-relaxed whitespace-pre-wrap">
        <%= extract_text(@message.content) %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @doc "Format a token count as a compact string: 847 → \"847\", 1234 → \"1.2k\", 1200000 → \"1.2M\"."
  @spec format_number(non_neg_integer() | nil) :: String.t()
  def format_number(nil), do: "0"
  def format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  def format_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}k"
  def format_number(n), do: "#{n}"

  @doc "Format context usage as a percentage of the context window."
  @spec format_context(non_neg_integer() | nil, pos_integer() | nil) :: String.t()
  def format_context(nil, _), do: ""
  def format_context(_, nil), do: ""
  def format_context(0, _), do: ""

  def format_context(tokens, window) when window > 0 do
    pct = Float.round(tokens / window * 100, 1)
    "ctx #{pct}%"
  end

  def format_context(_, _), do: ""

  @doc "Format a cost in dollars: 0.0 → \"-\", 0.001 → \"$0.00\", 1.5 → \"$1.50\"."
  @spec format_cost(float() | nil) :: String.t()
  def format_cost(nil), do: "-"
  def format_cost(cost) when cost == 0.0, do: "-"
  def format_cost(cost) when cost < 0.01, do: "<$0.01"
  def format_cost(cost), do: "$#{:erlang.float_to_binary(cost, decimals: 2)}"

  @spec format_usage(nil | map()) :: String.t()
  defp format_usage(nil), do: "↓0 ↑0"

  defp format_usage(%{input_tokens: i, output_tokens: o}),
    do: "↓#{format_number(i)} ↑#{format_number(o)}"

  defp format_usage(%{input: i, output: o}), do: "↓#{format_number(i)} ↑#{format_number(o)}"

  @spec extract_text(list() | term()) :: String.t()
  defp extract_text(content) when is_list(content) do
    content
    |> Enum.filter(&match?({:text, _}, &1))
    |> Enum.map_join("", fn {:text, t} -> t end)
  end

  defp extract_text(_), do: ""
end
