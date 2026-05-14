# Planck — Project Specification

> Named after the Planck length — the smallest meaningful distance.
>
> A full Elixir reimagining of the [pi-mono](https://github.com/badlogic/pi-mono) coding agent
> ecosystem. Agent processes are BEAM processes. Inter-agent communication is message passing.
> The TUI and Web UI are published to Hex.pm as reusable primitives. The coding agent ships
> as a standalone Burrito binary called `planck`.

---

## Table of Contents

1. [Goals & Principles](#1-goals--principles)
2. [Monorepo Structure](#2-monorepo-structure)
3. [Release Strategy](#3-release-strategy)
4. [Package: `planck_ai`](#4-package-planck_ai)
5. [Package: `planck_agent`](#5-package-planck_agent)
6. [Package: `planck_tui`](#6-package-planck_tui)
7. [Package: `planck_web`](#7-package-planck_web)
8. [Package: `planck` (coding agent)](#8-package-planck-coding-agent)
9. [Extension System](#9-extension-system)
10. [Skills](#10-skills)
11. [Prompt Templates](#11-prompt-templates)
12. [Themes](#12-themes)
13. [Session Persistence](#13-session-persistence)
14. [Build Order & Milestones](#14-build-order--milestones)
15. [Key Libraries](#15-key-libraries)

---

## 1. Goals & Principles

### What we're building

A coding agent CLI (`planck`) with feature parity with pi-coding-agent — file tools, bash
execution, session management, context compaction, extensions, skills, themes, prompt
templates — plus reusable TUI and Web UI libraries that any Elixir developer can use
independently.

### Core design principles

- **Agents are processes.** Each agent instance is a `GenServer`. Subagents are spawned
  processes supervised under a `DynamicSupervisor`. Inter-agent communication is message
  passing. No special "subagent" abstraction needed — it's just the BEAM.

- **OTP all the way down.** Supervision trees, fault tolerance, and process linking are not
  add-ons — they're the architecture. An agent crash doesn't take down the TUI.

- **Libraries on Hex, CLI as binary.** `planck_tui` and `planck_web` are usable by any
  Elixir developer building AI-powered apps. The coding agent is a self-contained Burrito
  binary that non-Elixir users can install without knowing about Mix or Erlang.

- **Extensions don't require compilation.** The primary extension path is a plain `.ex`
  source file loaded via `Code.compile_file/2` at startup — no build step. A script path
  using `Mix.install` covers extensions with Hex dependencies. Precompiled `.beam`
  extensions are the power path for custom TUI components.

- **UI is a protocol, not a library dependency.** Extensions communicate with the TUI through
  typed message structs via `GenServer.call`. They never import `planck_tui` directly. This
  keeps the rendering surface crash-safe and the extension interface stable across versions.

---

## 2. Monorepo Structure

Elixir umbrella project. All apps share a single `mix.exs` workspace, version-locked,
released simultaneously.

```
planck/
├── apps/
│   ├── planck_ai/          # LLM provider abstraction     → Hex library
│   ├── planck_agent/       # OTP agent runtime            → Hex library
│   ├── planck_tui/         # Terminal UI primitives       → Hex library
│   ├── planck_web/         # Phoenix LiveView components  → Hex library
│   └── planck/             # Coding agent CLI             → Burrito binary
├── mix.exs
├── mix.lock
├── .formatter.exs
├── .credo.exs
└── README.md
```

### Root `mix.exs`

```elixir
defmodule Planck.Umbrella.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      apps_path: "apps",
      version: @version,
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
```

---

## 3. Release Strategy

| Package | Distribution | Notes |
|---|---|---|
| `planck_ai` | Hex.pm | Standalone LLM library, no agent dep |
| `planck_agent` | Hex.pm | Depends on `planck_ai` |
| `planck_tui` | Hex.pm | Standalone; brings in ex_ratatui NIF |
| `planck_web` | Hex.pm | Depends on Phoenix + LiveView |
| `planck` (CLI) | Burrito binary + GitHub Releases | Depends on all of the above |

The coding agent binary bundles the Erlang runtime. End users install it with:

```sh
curl -fsSL https://planck.dev/install.sh | sh
```

Or via asdf/mise plugin. No Elixir or Erlang knowledge required.

---

## 4. Package: `planck_ai`

### Purpose

Unified LLM abstraction over multiple providers. Built on top of `req_llm`. Defines the
canonical streaming event protocol that `planck_agent` consumes.

### Dependencies

```elixir
{:req_llm, "~> 1.9"},
{:jason, "~> 1.4"},
{:nimble_options, "~> 1.0"}
```

### Core types

```elixir
defmodule Planck.AI.Model do
  @type t :: %__MODULE__{
    id: String.t(),
    name: String.t(),
    provider: atom(),
    context_window: pos_integer(),
    max_tokens: pos_integer(),
    supports_thinking: boolean(),
    input_types: [:text | :image],
    cost: %{input: float(), output: float(), cache_read: float(), cache_write: float()}
  }
  defstruct [:id, :name, :provider, :context_window, :max_tokens,
             :supports_thinking, input_types: [:text], cost: %{}]
end

defmodule Planck.AI.Message do
  @type role :: :user | :assistant | :tool_result
  @type content_part ::
    {:text, String.t()}
    | {:image, binary(), String.t()}
    | {:tool_call, String.t(), String.t(), map()}
    | {:tool_result, String.t(), term()}
    | {:thinking, String.t()}

  @type t :: %__MODULE__{role: role(), content: [content_part()]}
  defstruct [:role, content: []]
end

defmodule Planck.AI.Context do
  @type t :: %__MODULE__{
    system: String.t() | nil,
    messages: [Planck.AI.Message.t()],
    tools: [Planck.AI.Tool.t()]
  }
  defstruct [system: nil, messages: [], tools: []]
end
```

### Streaming event protocol

The canonical event type consumed by the agent loop. All providers normalize to this shape.

```elixir
defmodule Planck.AI.StreamEvent do
  @type t ::
    {:start, %{model: String.t()}}
    | {:text_delta, String.t()}
    | {:thinking_delta, String.t()}
    | {:tool_call_delta, %{id: String.t(), name: String.t(), args_partial: String.t()}}
    | {:tool_call_complete, %{id: String.t(), name: String.t(), args: map()}}
    | {:done, %{stop_reason: atom(), usage: map()}}
    | {:error, term()}
end
```

### Tool schema DSL

```elixir
defmodule Planck.AI.Tool do
  @type t :: %__MODULE__{
    name: String.t(),
    description: String.t(),
    parameters: map()   # JSON Schema map
  }
  defstruct [:name, :description, :parameters]
end

# Usage:
defmodule MyTools do
  import Planck.AI.Tool.DSL

  def bash_tool do
    tool "bash",
      description: "Execute a shell command",
      parameters: %{
        type: "object",
        properties: %{
          command: %{type: "string", description: "The command to run"},
          timeout: %{type: "integer", description: "Timeout in ms"}
        },
        required: ["command"]
      }
  end
end
```

### Primary API

```elixir
defmodule PlanckAi do
  # Returns a Stream of Planck.AI.StreamEvent.t()
  @spec stream(Planck.AI.Model.t(), Planck.AI.Context.t(), keyword()) :: Enumerable.t()
  def stream(model, context, opts \\ [])

  # Collects stream into a complete response message
  @spec complete(Planck.AI.Model.t(), Planck.AI.Context.t(), keyword()) ::
    {:ok, Planck.AI.Message.t()} | {:error, term()}
  def complete(model, context, opts \\ [])

  @spec get_model(atom(), String.t()) :: {:ok, Planck.AI.Model.t()} | {:error, :not_found}
  def get_model(provider, model_id)

  @spec list_models(atom()) :: [Planck.AI.Model.t()]
  def list_models(provider)

  @spec list_providers() :: [atom()]
  def list_providers()
end
```

### Streaming normalization over req_llm

The key challenge is partial JSON parsing for streaming tool arguments. `req_llm` returns
`StreamChunk` structs which we normalize into `Planck.AI.StreamEvent` tuples:

```elixir
defmodule Planck.AI.Stream do
  def from_req_llm(req_llm_stream) do
    req_llm_stream
    |> Stream.transform(%{tool_buffers: %{}}, &normalize_chunk/2)
  end

  defp normalize_chunk(%{type: :text, content: text}, state) do
    {[{:text_delta, text}], state}
  end

  defp normalize_chunk(%{type: :thinking, content: text}, state) do
    {[{:thinking_delta, text}], state}
  end

  defp normalize_chunk(%{type: :tool_call, id: id, name: name, args_delta: delta}, state) do
    buffer = Map.get(state.tool_buffers, id, "")
    new_buffer = buffer <> delta
    new_state = put_in(state.tool_buffers[id], new_buffer)
    event = {:tool_call_delta, %{id: id, name: name, args_partial: new_buffer}}
    {[event], new_state}
  end

  defp normalize_chunk(%{type: :tool_call_complete, id: id, name: name}, state) do
    raw = Map.get(state.tool_buffers, id, "")
    case Jason.decode(raw) do
      {:ok, args} -> {[{:tool_call_complete, %{id: id, name: name, args: args}}], state}
      {:error, _} -> {[{:error, {:invalid_tool_args, id, raw}}], state}
    end
  end

  defp normalize_chunk(%{type: :done, stop_reason: reason, usage: usage}, state) do
    {[{:done, %{stop_reason: reason, usage: usage}}], state}
  end
end
```

---

## 5. Package: `planck_agent`

### Purpose

OTP-based agent runtime. Each agent is a `GenServer`. Tool execution uses `Task.async_stream`.
Events broadcast via Registry-based pub/sub (no Phoenix dependency at this layer).

### Dependencies

```elixir
{:planck_ai, "~> 0.1"},
{:jason, "~> 1.4"}
```

### Agent state

```elixir
defmodule Planck.Agent.State do
  @type t :: %__MODULE__{
    id: String.t(),
    model: Planck.AI.Model.t() | nil,
    system_prompt: String.t(),
    messages: [Planck.Agent.Message.t()],
    tools: %{String.t() => Planck.Agent.Tool.t()},
    thinking_level: :off | :minimal | :low | :medium | :high | :xhigh,
    status: :idle | :streaming | :executing_tools,
    stream_ref: reference() | nil,
    pending_tool_calls: [map()]
  }
  defstruct [
    :id, :model, :stream_ref,
    system_prompt: "",
    messages: [],
    tools: %{},
    thinking_level: :off,
    status: :idle,
    pending_tool_calls: []
  ]
end
```

### Agent message types

Custom message types (UI-only) are filtered out before sending to the LLM:

```elixir
defmodule Planck.Agent.Message do
  @type role :: :user | :assistant | :tool_result | {:custom, atom()}

  @type t :: %__MODULE__{
    id: String.t(),
    role: role(),
    content: term(),
    timestamp: DateTime.t(),
    metadata: map()
  }
  defstruct [:id, :role, :content, :timestamp, metadata: %{}]

  def to_llm_messages(messages) do
    messages
    |> Enum.reject(fn m -> match?({:custom, _}, m.role) end)
    |> Enum.map(&to_planck_ai_message/1)
  end
end
```

### GenServer — agent loop

```elixir
defmodule Planck.Agent.Agent do
  use GenServer

  # Public API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @spec prompt(pid() | atom(), String.t() | map(), keyword()) :: :ok
  def prompt(agent, content, opts \\ []) do
    GenServer.cast(agent, {:prompt, content, opts})
  end

  @spec abort(pid() | atom()) :: :ok
  def abort(agent), do: GenServer.cast(agent, :abort)

  @spec get_state(pid() | atom()) :: Planck.Agent.State.t()
  def get_state(agent), do: GenServer.call(agent, :get_state)

  @spec subscribe(pid() | atom(), pid()) :: :ok
  def subscribe(agent, subscriber \\ self()) do
    GenServer.call(agent, {:subscribe, subscriber})
  end

  # Callbacks

  @impl true
  def init(opts) do
    state = %Planck.Agent.State{
      id: opts[:id] || UUID.uuid4(),
      model: opts[:model],
      system_prompt: opts[:system_prompt] || "",
      tools: opts[:tools] || %{},
      thinking_level: opts[:thinking_level] || :off
    }
    {:ok, state}
  end

  @impl true
  def handle_cast({:prompt, content, _opts}, state) do
    message = build_user_message(content)
    new_state = %{state | messages: state.messages ++ [message], status: :streaming}
    broadcast(state.id, {:agent_event, :turn_start, %{}})
    {:noreply, new_state, {:continue, :run_llm}}
  end

  @impl true
  def handle_continue(:run_llm, state) do
    context = build_context(state)
    parent = self()
    ref = make_ref()

    Task.start(fn ->
      state.model
      |> Planck.AI.stream(context)
      |> Enum.each(fn event -> send(parent, {:stream_event, ref, event}) end)
      send(parent, {:stream_done, ref})
    end)

    {:noreply, %{state | stream_ref: ref}}
  end

  @impl true
  def handle_info({:stream_event, ref, event}, %{stream_ref: ref} = state) do
    broadcast(state.id, {:agent_event, :message_update, event})
    {:noreply, accumulate_stream_event(state, event)}
  end

  def handle_info({:stream_done, ref}, %{stream_ref: ref} = state) do
    case state.pending_tool_calls do
      [] ->
        new_state = %{state | status: :idle, stream_ref: nil, pending_tool_calls: []}
        broadcast(state.id, {:agent_event, :turn_end, %{}})
        {:noreply, new_state}

      tool_calls ->
        new_state = %{state | status: :executing_tools}
        {:noreply, new_state, {:continue, {:execute_tools, tool_calls}}}
    end
  end

  @impl true
  def handle_continue({:execute_tools, tool_calls}, state) do
    parent = self()

    results =
      tool_calls
      |> Task.async_stream(
        fn call ->
          tool = Map.get(state.tools, call.name)
          broadcast(state.id, {:agent_event, :tool_execution_start, call})
          result = Planck.Agent.Tool.execute(tool, call.id, call.args, parent)
          broadcast(state.id, {:agent_event, :tool_execution_end, %{call: call, result: result}})
          {call.id, result}
        end,
        max_concurrency: 4,
        timeout: 60_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    tool_result_msg = build_tool_result_message(results)
    new_state = %{state |
      messages: state.messages ++ [tool_result_msg],
      pending_tool_calls: [],
      status: :streaming
    }

    {:noreply, new_state, {:continue, :run_llm}}
  end

  defp broadcast(agent_id, event) do
    Registry.dispatch(Planck.Agent.Registry, agent_id, fn entries ->
      for {pid, _} <- entries, do: send(pid, event)
    end)
  end
end
```

### Tool definition

```elixir
defmodule Planck.Agent.Tool do
  @type update_callback :: (term() -> :ok)

  @type t :: %__MODULE__{
    name: String.t(),
    description: String.t(),
    schema: map(),
    execute_fn: (String.t(), map(), update_callback()) -> {:ok, term()} | {:error, term()}
  }
  defstruct [:name, :description, :schema, :execute_fn]

  def execute(%__MODULE__{execute_fn: fun}, call_id, args, parent_pid) do
    update_fn = fn partial -> send(parent_pid, {:tool_update, call_id, partial}) end
    fun.(call_id, args, update_fn)
  end
end

# Convenience macro
defmodule Planck.Agent.Tool.Builder do
  defmacro deftool(name, opts, do: block) do
    quote do
      %Planck.Agent.Tool{
        name: unquote(name),
        description: unquote(opts[:description]),
        schema: unquote(opts[:schema]),
        execute_fn: fn tool_call_id, args, on_update ->
          var!(args) = args
          var!(tool_call_id) = tool_call_id
          var!(on_update) = on_update
          unquote(block)
        end
      }
    end
  end
end
```

### Supervision tree

```elixir
defmodule Planck.Agent.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :duplicate, name: Planck.Agent.Registry},
      {DynamicSupervisor, name: Planck.Agent.AgentSupervisor, strategy: :one_for_one}
    ]
    Supervisor.init(children, strategy: :one_for_all)
  end
end

# Spawning a subagent from within a tool:
def spawn_subagent(model, system_prompt, tools) do
  spec = {Planck.Agent.Agent, id: UUID.uuid4(), model: model,
                              system_prompt: system_prompt, tools: tools}
  {:ok, pid} = DynamicSupervisor.start_child(Planck.Agent.AgentSupervisor, spec)
  pid
end
```

---

## 6. Package: `planck_tui`

### Purpose

Terminal UI primitives built on `ex_ratatui` (Rust ratatui bindings via Rustler NIFs).
Published to Hex as a standalone library usable in any Elixir terminal application.

### Dependencies

```elixir
{:ex_ratatui, github: "mcass19/ex_ratatui"},
{:jason, "~> 1.4"}
```

### Application behaviour

We use ex_ratatui's **Reducer** mode (Elm-like: init/update/render) as it maps cleanly to
`planck_agent` event streams.

```elixir
defmodule Planck.TUI.App do
  @callback init(args :: term()) :: state :: term()
  @callback update(state :: term(), event :: term()) :: state :: term()
  @callback render(state :: term()) :: ExRatatui.widget()
  @callback handle_key(state :: term(), key :: ExRatatui.Key.t()) ::
    {:noreply, term()} | {:emit, term(), term()} | :exit

  defmacro __using__(_opts) do
    quote do
      @behaviour Planck.TUI.App
      use ExRatatui.App, mode: :reducer
    end
  end
end
```

### Chat message list widget

```elixir
defmodule Planck.TUI.Widgets.MessageList do
  @doc """
  Renders a list of PlanckAgent messages.
  Handles: text (markdown), thinking blocks, tool call/result rows, diffs, custom messages.
  """
  def render(messages, opts \\ []) do
    theme = opts[:theme] || Planck.TUI.Theme.default()
    expanded_tools = opts[:expanded_tools] || false

    messages
    |> Enum.flat_map(&render_message(&1, theme, expanded_tools))
    |> ExRatatui.Widgets.List.new()
    |> ExRatatui.Widgets.List.highlight_style(theme.selected_style)
  end

  defp render_message(%{role: :assistant, content: content}, theme, expanded) do
    Enum.flat_map(content, fn
      {:text, text}               -> render_markdown(text, theme)
      {:thinking, text}           -> render_thinking_block(text, theme)
      {:tool_call, id, name, args} -> render_tool_call(id, name, args, theme, expanded)
    end)
  end

  defp render_message(%{role: :user, content: content}, theme, _) do
    [ExRatatui.Widgets.Paragraph.new(content)
     |> ExRatatui.Widgets.Paragraph.style(theme.user_message_style)]
  end

  defp render_message(%{role: {:custom, _type}} = msg, theme, _) do
    render_custom_message(msg, theme)
  end
end
```

### Diff widget

```elixir
defmodule Planck.TUI.Widgets.Diff do
  def render(diff_text, theme) do
    diff_text
    |> String.split("\n")
    |> Enum.map(fn
      "+" <> rest -> ExRatatui.line([{rest, theme.diff_added_style}])
      "-" <> rest -> ExRatatui.line([{rest, theme.diff_removed_style}])
      " " <> rest -> ExRatatui.line([{rest, theme.diff_context_style}])
      line        -> ExRatatui.line([{line, theme.muted_style}])
    end)
    |> ExRatatui.Widgets.List.new()
  end
end
```

### Chat input widget

```elixir
defmodule Planck.TUI.Widgets.ChatInput do
  @doc """
  Multi-line input with slash command and file path autocomplete.
  Paste handling collapses large pastes (>10 lines) with a marker.
  """

  defstruct [
    text: "",
    cursor: 0,
    autocomplete: nil,
    history: [],
    history_idx: nil
  ]

  def new(opts \\ []), do: struct(__MODULE__, opts)

  def handle_key(%__MODULE__{} = input, key, autocomplete_providers) do
    case key do
      %{code: {:char, "/"}} when input.text == "" ->
        completions = get_slash_completions(autocomplete_providers, "/")
        %{input | autocomplete: completions}

      %{code: :tab} when not is_nil(input.autocomplete) ->
        apply_completion(input)

      %{code: :enter, modifiers: []} ->
        {:submit, input.text, %{input | text: "", cursor: 0}}

      _ ->
        {input, nil}
    end
  end

  def render(%__MODULE__{} = input, theme, opts \\ []) do
    base =
      ExRatatui.Widgets.TextInput.new(input.text)
      |> ExRatatui.Widgets.TextInput.cursor_position(input.cursor)
      |> ExRatatui.Widgets.Block.borders(:all)
      |> ExRatatui.Widgets.Block.border_style(theme.border_style)

    case input.autocomplete do
      nil -> base
      completions -> render_with_autocomplete(base, completions, theme, opts[:width] || 80)
    end
  end
end
```

### UI protocol (UIBridge)

Extensions communicate with the TUI via typed structs — they never import `planck_tui`.

```elixir
defmodule Planck.TUI.UIBridge do
  @doc "Send a UI request to the TUI process and await a response."
  @spec request(pid(), term(), timeout()) :: term()
  def request(tui_pid, req, timeout \\ 30_000) do
    GenServer.call(tui_pid, {:ui_request, req}, timeout)
  end

  def select(ui, title, options, opts \\ []) do
    request(ui, {:dialog, :select, title, options, opts})
  end

  def confirm(ui, title, message, opts \\ []) do
    request(ui, {:dialog, :confirm, title, message, opts})
  end

  def input(ui, title, opts \\ []) do
    request(ui, {:dialog, :input, title, opts})
  end

  def notify(ui, message, type \\ :info) do
    request(ui, {:notify, message, type})
  end

  def set_status(ui, key, text) do
    request(ui, {:set_status, key, text})
  end

  def set_widget(ui, key, segments, placement \\ :above) do
    request(ui, {:set_widget, key, segments, placement})
  end
end

# Widget segment vocabulary — what extensions can pass without importing planck_tui
defmodule Planck.TUI.UISegment do
  @type t ::
    {:text, String.t(), style: atom()}
    | {:gauge, 0..100, label: String.t()}
    | {:separator}
    | {:spinner, label: String.t()}
end
```

---

## 7. Package: `planck_web`

### Purpose

Phoenix LiveView components for AI chat interfaces. Handles streaming LLM output via
PubSub, session management, artifact rendering, and file attachments. Publishable to Hex
for use in any Phoenix application.

### Dependencies

```elixir
{:planck_agent, "~> 0.1"},
{:phoenix_live_view, "~> 1.0"},
{:phoenix_pubsub, "~> 2.0"},
{:ecto_sqlite3, "~> 0.15"},
{:jason, "~> 1.4"}
```

### LiveView chat component

```elixir
defmodule Planck.Web.ChatLive do
  use Phoenix.LiveView
  alias Planck.Agent.Agent

  def mount(_params, _session, socket) do
    {:ok, agent} = DynamicSupervisor.start_child(
      Planck.Agent.AgentSupervisor,
      {Agent, id: UUID.uuid4(), model: default_model()}
    )

    if connected?(socket), do: Agent.subscribe(agent)

    {:ok, assign(socket, agent: agent, messages: [], streaming: false, input: "")}
  end

  def handle_event("submit", %{"message" => text}, socket) do
    Agent.prompt(socket.assigns.agent, text)
    {:noreply, assign(socket, streaming: true, input: "")}
  end

  def handle_info({:agent_event, :message_update, event}, socket) do
    # Push streaming token to browser via JS hook
    {:noreply, push_event(socket, "stream_chunk", %{event: event})}
  end

  def handle_info({:agent_event, :turn_end, _}, socket) do
    messages = Agent.get_state(socket.assigns.agent).messages
    {:noreply, assign(socket, messages: messages, streaming: false)}
  end

  def render(assigns) do
    ~H"""
    <div class="planck-chat" id="chat" phx-hook="StreamingChat">
      <.message_list messages={@messages} />
      <.chat_input value={@input} streaming={@streaming} />
    </div>
    """
  end
end
```

### Artifacts panel

HTML/SVG/Markdown artifacts run in a sandboxed `<iframe>` — inherently browser-side
regardless of the server language. Communication via `postMessage`.

```elixir
defmodule Planck.Web.ArtifactsLive do
  use Phoenix.LiveComponent

  def render(assigns) do
    ~H"""
    <div class="planck-artifacts">
      <%= for artifact <- @artifacts do %>
        <div class="artifact" id={"artifact-#{artifact.id}"}>
          <h3><%= artifact.title %></h3>
          <iframe
            sandbox="allow-scripts"
            phx-hook="ArtifactFrame"
            data-artifact-id={artifact.id}
            data-content={Jason.encode!(artifact.content)}
          />
        </div>
      <% end %>
    </div>
    """
  end
end
```

### Storage

Replaces IndexedDB with server-side Ecto (SQLite default, Postgres optional):

```elixir
defmodule Planck.Web.Schema.Session do
  use Ecto.Schema

  schema "sessions" do
    field :title, :string
    field :model_id, :string
    field :messages, {:array, :map}, default: []
    field :metadata, :map, default: %{}
    timestamps()
  end
end

defmodule Planck.Web.Schema.ApiKey do
  use Ecto.Schema

  schema "api_keys" do
    field :provider, :string
    field :key_encrypted, :binary   # encrypted at rest
    field :user_id, :string
    timestamps()
  end
end
```

---

## 8. Package: `planck` (Coding Agent)

### Purpose

The coding agent CLI. Depends on all other packages. Distributed as a Burrito binary.
Interactive mode uses `planck_tui`. Non-interactive (print/pipe) mode streams to stdout.

### Dependencies

```elixir
{:planck_ai, "~> 0.1"},
{:planck_agent, "~> 0.1"},
{:planck_tui, "~> 0.1"},
{:burrito, "~> 1.0"},
{:optimus, "~> 0.2"},
{:yaml_elixir, "~> 2.9"},
{:file_system, "~> 1.0"},
{:ecto_sqlite3, "~> 0.15"},
{:req, "~> 0.5"}
```

### Burrito configuration

```elixir
# In apps/planck/mix.exs
def releases do
  [
    planck: [
      steps: [:assemble, &Burrito.wrap/1],
      burrito: [
        targets: [
          macos_arm:  [os: :darwin,  cpu: :aarch64],
          macos_x86:  [os: :darwin,  cpu: :x86_64],
          linux_x86:  [os: :linux,   cpu: :x86_64],
          linux_arm:  [os: :linux,   cpu: :aarch64],
          windows:    [os: :windows, cpu: :x86_64]
        ]
      ]
    ]
  ]
end
```

### Extension loading at startup

```elixir
defmodule Planck.Startup do
  @doc """
  Load extensions in priority order:
    1. Source extensions (.ex)  — Code.compile_file, no build step
    2. Script extensions (.exs) — Code.eval_file, supports Mix.install for deps
    3. Compiled extensions      — :code.add_path + :code.load_abs for ebin/ dirs
  """
  def load_extensions(cwd) do
    paths = discover_extension_paths(cwd)
    Enum.reduce(paths, [], fn path, acc ->
      case load_extension(path) do
        {:ok, mod} ->
          [mod | acc]
        {:error, reason} ->
          warn("Failed to load extension #{path}: #{inspect(reason)}")
          acc
      end
    end)
  end

  defp discover_extension_paths(cwd) do
    local  = Path.join([cwd, ".planck", "extensions"])
    global = Path.join([System.user_home!(), ".planck", "extensions"])

    [local, global]
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(&list_extension_entries/1)
  end

  defp load_extension(path) do
    cond do
      String.ends_with?(path, ".ex") ->
        # Compile in memory — works inside Burrito (compiler is compiled BEAM)
        [{mod, _bytecode} | _] = Code.compile_file(path)
        {:ok, mod}

      String.ends_with?(path, ".exs") ->
        # Script with optional Mix.install for Hex deps
        Code.eval_file(path)
        {:ok, :script}

      File.dir?(path) ->
        ebin = Path.join(path, "ebin")
        if File.dir?(ebin) do
          :code.add_path(String.to_charlist(ebin))
          load_beams_from_ebin(ebin)
        else
          {:error, :no_ebin}
        end

      true ->
        {:error, :unknown_format}
    end
  rescue
    e -> {:error, e}
  end
end
```

### Extension behaviour

```elixir
defmodule Planck.Extension do
  @doc "Called once at startup with the extension API handle."
  @callback init(api :: Planck.ExtensionAPI.t()) :: :ok | {:error, term()}
  @optional_callbacks [init: 1]
end

defmodule Planck.ExtensionAPI do
  @type t :: %__MODULE__{
    agent_pid: pid(),
    tui_pid: pid() | nil,
    session: Planck.Session.t()
  }
  defstruct [:agent_pid, :tui_pid, :session]

  def on(%__MODULE__{agent_pid: pid}, event_type, handler) do
    Planck.EventBus.subscribe(pid, event_type, handler)
  end

  def register_tool(%__MODULE__{agent_pid: pid}, tool) do
    Planck.Agent.Agent.add_tool(pid, tool)
  end

  def register_command(%__MODULE__{} = api, name, opts) do
    Planck.SlashCommands.register(api, name, opts)
  end

  # UI access via UIBridge — extension doesn't import planck_tui
  def ui(%__MODULE__{tui_pid: tui_pid}), do: tui_pid
end
```

### Example: source extension (no compilation)

```elixir
# ~/.planck/extensions/auto_commit.ex
defmodule AutoCommitExtension do
  @behaviour Planck.Extension

  @impl true
  def init(api) do
    Planck.ExtensionAPI.on(api, :agent_end, fn _event, ctx ->
      Planck.TUI.UIBridge.notify(ctx.ui, "Turn complete", :info)
    end)

    Planck.ExtensionAPI.register_command(api, "commit", [
      description: "Ask the agent to write a git commit message",
      handler: fn _args, ctx ->
        Planck.Agent.Agent.prompt(ctx.agent_pid, "Write a git commit message for recent changes")
      end
    ])
  end
end
```

### Example: script extension with a Hex dependency

```elixir
# ~/.planck/extensions/webhook.exs
Mix.install([:req])

defmodule WebhookExtension do
  @behaviour Planck.Extension

  @impl true
  def init(api) do
    Planck.ExtensionAPI.on(api, :agent_end, fn _event, _ctx ->
      Req.post!("https://hooks.example.com/planck", json: %{status: "done"})
    end)
  end
end
```

### Core tools

```elixir
defmodule Planck.Tools do
  import Planck.Agent.Tool.Builder

  def all, do: [bash(), read(), write(), edit(), grep(), find(), ls()]

  def bash do
    deftool "bash",
      description: "Execute a shell command. Output streams in real time.",
      schema: %{
        type: "object",
        properties: %{
          command: %{type: "string"},
          timeout_ms: %{type: "integer", default: 120_000}
        },
        required: ["command"]
      } do
        Planck.BashExecutor.run(args["command"],
          timeout: args["timeout_ms"] || 120_000,
          on_output: fn data -> on_update.({:output, data}) end
        )
    end
  end

  def edit do
    deftool "edit",
      description: "Replace exact text in a file. Fails if old_string is not found.",
      schema: %{
        type: "object",
        properties: %{
          file_path:   %{type: "string"},
          old_string:  %{type: "string"},
          new_string:  %{type: "string"},
          replace_all: %{type: "boolean", default: false}
        },
        required: ["file_path", "old_string", "new_string"]
      } do
        path = args["file_path"]
        content = File.read!(path)
        replace_fn = if args["replace_all"], do: &String.replace/3, else: &replace_first/3

        case replace_fn.(content, args["old_string"], args["new_string"]) do
          ^content     -> {:error, "old_string not found in #{path}"}
          new_content  ->
            File.write!(path, new_content)
            {:ok, %{path: path, diff: Planck.Diff.generate(content, new_content, path)}}
        end
    end
  end

  def read do
    deftool "read",
      description: "Read a file. Returns content with line numbers.",
      schema: %{
        type: "object",
        properties: %{
          file_path: %{type: "string"},
          offset: %{type: "integer"},
          limit: %{type: "integer"}
        },
        required: ["file_path"]
      } do
        path = args["file_path"]
        lines = File.stream!(path) |> Enum.to_list()
        offset = (args["offset"] || 1) - 1
        limit = args["limit"] || length(lines)
        slice = Enum.slice(lines, offset, limit)
        numbered = slice |> Enum.with_index(offset + 1) |> Enum.map_join(fn {l, n} -> "#{n}\t#{l}" end)
        {:ok, numbered}
    end
  end
end
```

### Bash executor via Port

```elixir
defmodule Planck.BashExecutor do
  def run(command, opts \\ []) do
    timeout   = opts[:timeout] || 120_000
    cwd       = opts[:cwd] || File.cwd!()
    on_output = opts[:on_output]

    port = Port.open(
      {:spawn_executable, System.find_executable("bash")},
      [:binary, :exit_status, :stderr_to_stdout,
       args: ["-c", command],
       cd: cwd]
    )

    collect(port, "", timeout, on_output)
  end

  defp collect(port, acc, timeout, on_output) do
    receive do
      {^port, {:data, data}} ->
        if on_output, do: on_output.(data)
        collect(port, acc <> data, timeout, on_output)

      {^port, {:exit_status, code}} ->
        {:ok, %{output: acc, exit_code: code}}
    after
      timeout ->
        Port.close(port)
        {:error, :timeout}
    end
  end
end
```

### Context compaction (pure function)

```elixir
defmodule Planck.Compaction do
  @doc """
  When context approaches capacity, summarize early messages and replace them
  with a compaction entry. Pure function — no side effects.
  """
  def maybe_compact(messages, model, opts \\ []) do
    threshold = opts[:threshold] || 0.8
    token_count = estimate_tokens(messages)

    if token_count / model.context_window > threshold do
      compact(messages, model, opts)
    else
      {:ok, messages}
    end
  end

  def compact(messages, model, opts \\ []) do
    {to_summarize, to_keep} = split_at_boundary(messages)
    custom = opts[:custom_instructions] || ""

    with {:ok, summary_msg} <- summarize(to_summarize, model, custom) do
      compaction_entry = %Planck.Agent.Message{
        id: UUID.uuid4(),
        role: {:custom, :compaction},
        content: %{summary: summary_msg, replaced_count: length(to_summarize)},
        timestamp: DateTime.utc_now()
      }
      {:compacted, [compaction_entry | to_keep]}
    end
  end

  defp summarize(messages, model, custom_instructions) do
    prompt = """
    Summarize the following conversation for use as context. Be concise but complete.
    #{if custom_instructions != "", do: "\n#{custom_instructions}", else: ""}

    #{format_messages(messages)}
    """
    context = %Planck.AI.Context{
      messages: [%Planck.AI.Message{role: :user, content: [{:text, prompt}]}]
    }
    Planck.AI.complete(model, context)
  end
end
```

---

## 9. Extension System

### Three-tier loading

| Tier | File | Deps | Compilation |
|---|---|---|---|
| Source | `~/.planck/extensions/my_ext.ex` | Binary modules only | None — `Code.compile_file` |
| Script | `~/.planck/extensions/my_ext.exs` | `Mix.install([...])` | None — `Code.eval_file` |
| Compiled | `~/.planck/extensions/my_ext/ebin/*.beam` | Any | `mix compile` by author |

The compiled tier is primarily for extensions that need to provide custom TUI components
(which require `planck_tui` as a compile-time dependency).

### Discovery paths (in priority order)

1. `{cwd}/.planck/extensions/` — project-local
2. `~/.planck/extensions/` — global user
3. Paths from `--extension` CLI flag or `extensions:` in `~/.planck/config.yaml`

### Event types

```elixir
defmodule Planck.Events do
  @type t ::
    {:resources_discover, %{cwd: String.t(), reason: :startup | :reload}}
    | {:session_start,    %{reason: atom()}}
    | {:session_shutdown, %{}}
    | {:agent_start,      %{}}
    | {:agent_end,        %{messages: list()}}
    | {:turn_start,       %{index: non_neg_integer()}}
    | {:turn_end,         %{message: map()}}
    | {:before_agent_start, %{prompt: String.t(), system_prompt: String.t()}}
    | {:tool_call,        %{id: String.t(), name: String.t(), args: map()}}
    | {:tool_result,      %{id: String.t(), name: String.t(), result: term(), error: boolean()}}
    | {:context,          %{messages: list()}}
    | {:model_select,     %{model: Planck.AI.Model.t()}}
    | {:input,            %{text: String.t(), source: :interactive | :extension}}
    | {:user_bash,        %{command: String.t(), cwd: String.t()}}
end
```

### EventBus

```elixir
defmodule Planck.EventBus do
  def subscribe(agent_pid, event_type, handler) when is_function(handler, 2) do
    Registry.register(Planck.EventRegistry, {agent_pid, event_type}, handler)
  end

  def dispatch(agent_pid, event) do
    event_type = elem(event, 0)
    ctx = build_context(agent_pid)

    Registry.lookup(Planck.EventRegistry, {agent_pid, event_type})
    |> Enum.map(fn {_pid, handler} -> handler end)
    |> Enum.reduce_while({:ok, event}, fn handler, {:ok, evt} ->
      case handler.(evt, ctx) do
        {:block, reason}    -> {:halt, {:blocked, reason}}
        {:transform, new}   -> {:cont, {:ok, new}}
        _                   -> {:cont, {:ok, evt}}
      end
    end)
  end
end
```

---

## 10. Skills

Skills are markdown files with YAML frontmatter. The LLM is told about them in the system
prompt and loads them on demand with the `read` tool.

### File convention

```
~/.planck/skills/
  my-skill/
    SKILL.md        # entry point — name must match parent directory
    helper.md       # referenced files the skill can instruct the LLM to read
  simple.md         # single-file skill (flat)

{cwd}/.planck/skills/
  project-skill/
    SKILL.md
```

### SKILL.md format

```markdown
---
name: ecto-migration
description: Creates Ecto migrations following multi-tenant conventions
disable-model-invocation: false
---

When creating a migration, prefix tables with the tenant schema...
```

### Implementation

```elixir
defmodule Planck.Skills do
  @type t :: %__MODULE__{
    name: String.t(),
    description: String.t(),
    file_path: String.t(),
    base_dir: String.t(),
    disable_model_invocation: boolean()
  }
  defstruct [:name, :description, :file_path, :base_dir,
             disable_model_invocation: false]

  def load(opts \\ []) do
    cwd        = opts[:cwd] || File.cwd!()
    agent_dir  = opts[:agent_dir] || default_agent_dir()
    extra      = opts[:skill_paths] || []

    [
      load_from_dir(Path.join(agent_dir, "skills"), :user),
      load_from_dir(Path.join(cwd, ".planck/skills"), :project)
      | Enum.map(extra, &load_from_dir(&1, :path))
    ]
    |> List.flatten()
    |> deduplicate_by_name()
  end

  def format_for_system_prompt(skills) do
    visible = Enum.reject(skills, & &1.disable_model_invocation)
    if visible == [], do: "", else: build_xml(visible)
  end

  defp build_xml(skills) do
    items = Enum.map_join(skills, "\n", fn s ->
      """
        <skill>
          <name>#{xml_escape(s.name)}</name>
          <description>#{xml_escape(s.description)}</description>
          <location>#{xml_escape(s.file_path)}</location>
        </skill>
      """
    end)

    """

    The following skills provide specialized instructions for specific tasks.
    Use the read tool to load a skill's file when the task matches its description.
    When a skill references relative paths, resolve them against the skill's base directory.

    <available_skills>
    #{items}</available_skills>
    """
  end
end
```

---

## 11. Prompt Templates

Templates are `.md` files invoked via `/template-name arg1 arg2` in the input.

### Format

```markdown
---
description: Create an Ecto schema for a given resource
---
Create an Ecto schema for `$1` with these fields: $@.
Follow conventions in AGENTS.md.
```

### Argument substitution

Supports `$1 $2`, `$@`, `$ARGUMENTS`, and `${@:N}` / `${@:N:L}` slice syntax (bash-style).

```elixir
defmodule Planck.PromptTemplates do
  @type t :: %__MODULE__{
    name: String.t(),
    description: String.t(),
    content: String.t(),
    file_path: String.t()
  }
  defstruct [:name, :description, :content, :file_path]

  def load(opts \\ []) do
    cwd       = opts[:cwd] || File.cwd!()
    agent_dir = opts[:agent_dir] || default_agent_dir()
    dirs = [Path.join(agent_dir, "prompts"), Path.join(cwd, ".planck/prompts")]
    Enum.flat_map(dirs, &load_from_dir/1)
  end

  def expand(text, templates) do
    with "/" <> rest <- text,
         {name, args_str} <- split_name_args(rest),
         template when not is_nil(template) <- Enum.find(templates, &(&1.name == name)) do
      args = parse_args(args_str)
      substitute(template.content, args)
    else
      _ -> text
    end
  end

  defp substitute(content, args) do
    all_args = Enum.join(args, " ")

    content
    |> String.replace(~r/\$(\d+)/, fn _, n ->
      Enum.at(args, String.to_integer(n) - 1, "")
    end)
    |> String.replace(~r/\$\{@:(\d+)(?::(\d+))?\}/, fn _, start, len ->
      idx = max(String.to_integer(start) - 1, 0)
      case len do
        nil -> args |> Enum.drop(idx) |> Enum.join(" ")
        l   -> args |> Enum.slice(idx, String.to_integer(l)) |> Enum.join(" ")
      end
    end)
    |> String.replace(~r/\$(?:@|ARGUMENTS)/, all_args)
  end

  defp parse_args(str) do
    ~r/"[^"]*"|'[^']*'|\S+/
    |> Regex.scan(str)
    |> List.flatten()
    |> Enum.map(&(String.trim(&1, "\"") |> String.trim("'")))
  end
end
```

---

## 12. Themes

### JSON format

43 named color tokens, optional `vars` for aliases, truecolor/256-color auto-detection.

```json
{
  "$schema": "https://planck.dev/theme-schema.json",
  "name": "dark",
  "vars": {
    "primary": "#7c8cff",
    "subtle":  "#6b7280"
  },
  "colors": {
    "accent":          "primary",
    "border":          "subtle",
    "borderAccent":    "primary",
    "success":         "#4ade80",
    "error":           "#f87171",
    "warning":         "#fbbf24",
    "muted":           "subtle",
    "text":            "#e5e5e7",
    "mdHeading":       "primary",
    "toolDiffAdded":   "#4ade80",
    "toolDiffRemoved": "#f87171"
  }
}
```

### Theme module

```elixir
defmodule Planck.Theme do
  @type color_mode :: :truecolor | :"256color"

  defstruct [:name, :source_path, :fg_colors, :bg_colors, :mode]

  def load(name_or_path, opts \\ []) do
    mode = opts[:mode] || detect_color_mode()
    json = read_theme_json(name_or_path)
    resolved = resolve_vars(json["colors"], json["vars"] || %{})
    build_theme(json["name"], resolved, mode, name_or_path)
  end

  def fg(%__MODULE__{fg_colors: colors, mode: mode}, key, text) do
    "#{fg_escape(Map.fetch!(colors, key), mode)}#{text}\e[39m"
  end

  def bg(%__MODULE__{bg_colors: colors, mode: mode}, key, text) do
    "#{bg_escape(Map.fetch!(colors, key), mode)}#{text}\e[49m"
  end

  defp detect_color_mode do
    cond do
      System.get_env("COLORTERM") in ["truecolor", "24bit"] -> :truecolor
      System.get_env("WT_SESSION")                          -> :truecolor
      System.get_env("TERM_PROGRAM") == "Apple_Terminal"    -> :"256color"
      true                                                  -> :truecolor
    end
  end

  defp fg_escape("", _),          do: "\e[39m"
  defp fg_escape(n, _) when is_integer(n), do: "\e[38;5;#{n}m"
  defp fg_escape("#" <> _ = hex, :truecolor) do
    {r, g, b} = hex_to_rgb(hex)
    "\e[38;2;#{r};#{g};#{b}m"
  end
  defp fg_escape("#" <> _ = hex, :"256color"), do: "\e[38;5;#{hex_to_256(hex)}m"

  defp hex_to_rgb("#" <> hex) do
    <<r::binary-2, g::binary-2, b::binary-2>> = hex
    {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}
  end

  defp hex_to_256(hex) do
    {r, g, b} = hex_to_rgb(hex)
    cube = [0, 95, 135, 175, 215, 255]
    ri = nearest_idx(r, cube); gi = nearest_idx(g, cube); bi = nearest_idx(b, cube)
    cube_idx = 16 + 36 * ri + 6 * gi + bi
    spread = max(r, max(g, b)) - min(r, min(g, b))
    if spread < 10 do
      grays = Enum.map(0..23, &(8 + &1 * 10))
      gray = round(0.299 * r + 0.587 * g + 0.114 * b)
      232 + nearest_idx(gray, grays)
    else
      cube_idx
    end
  end
end
```

### Hot reload

```elixir
defmodule Planck.ThemeWatcher do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    dir = opts[:theme_dir] || custom_themes_dir()
    {:ok, watcher} = FileSystem.start_link(dirs: [dir])
    FileSystem.subscribe(watcher)
    {:ok, %{on_change: opts[:on_change]}}
  end

  @impl true
  def handle_info({:file_event, _, {path, _}}, state) do
    if String.ends_with?(path, ".json") do
      Process.send_after(self(), {:reload, path}, 100)
    end
    {:noreply, state}
  end

  def handle_info({:reload, path}, state) do
    with {:ok, theme} <- Planck.Theme.load(path) do
      if state.on_change, do: state.on_change.({:theme_reloaded, theme})
    end
    {:noreply, state}
  end
end
```

---

## 13. Session Persistence

### Schema

```elixir
defmodule Planck.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  def change do
    create table(:sessions) do
      add :name,        :string
      add :cwd,         :string, null: false
      add :model_id,    :string
      add :branch,      :string, default: "main"
      add :tags,        {:array, :string}, default: []
      add :token_count, :integer
      timestamps()
    end

    create table(:entries) do
      add :session_id, references(:sessions, on_delete: :delete_all), null: false
      add :type,       :string, null: false
      add :content,    :map, null: false
      add :parent_id,  references(:entries)
      add :is_leaf,    :boolean, default: true, null: false
      add :label,      :string
      timestamps(updated_at: false)
    end

    create index(:entries, [:session_id])
    create index(:entries, [:parent_id])
    create index(:entries, [:session_id, :is_leaf])
  end
end
```

### Session manager

```elixir
defmodule Planck.SessionManager do
  alias Planck.{Repo, Schema}
  import Ecto.Query

  def new_session(opts \\ []) do
    %Schema.Session{}
    |> Schema.Session.changeset(Map.new(opts))
    |> Repo.insert()
  end

  def append_entry(session_id, type, content, opts \\ []) do
    parent_id = opts[:parent_id] || get_leaf(session_id)

    if parent_id do
      Repo.update_all(from(e in Schema.Entry, where: e.id == ^parent_id), set: [is_leaf: false])
    end

    %Schema.Entry{}
    |> Schema.Entry.changeset(%{session_id: session_id, type: to_string(type),
                                content: content, parent_id: parent_id})
    |> Repo.insert()
  end

  def fork(session_id, entry_id) do
    session = Repo.get!(Schema.Session, session_id)
    new_session(cwd: session.cwd, model_id: session.model_id, branch: "fork-#{entry_id}")
  end

  def load_branch(session_id, leaf_id \\ nil) do
    leaf = leaf_id || get_leaf(session_id)
    walk_to_root(leaf)
  end
end
```

---

## 14. Build Order & Milestones

### Milestone 1 — Foundation (weeks 1–3)
- `planck_ai`: ReqLLM adapter, streaming event protocol, tool schema DSL, Anthropic + OpenAI + Ollama
- `planck_agent`: GenServer loop, parallel tool execution via `Task.async_stream`, Registry PubSub, supervision tree
- Unit tests for both with no TUI dependency

### Milestone 2 — Core Agent (weeks 4–6)
- `planck` core: file tools (read/write/edit/grep/find/ls), bash executor via Port
- Session persistence: Ecto + SQLite migrations + SessionManager
- Skills, prompt templates, theme loading (no hot reload yet)
- Print mode: non-interactive, streams markdown to stdout
- Runnable via `mix run` or escript for early testing

### Milestone 3 — TUI (weeks 7–9)
- `planck_tui`: MessageList, ChatInput, Diff, Throbber widgets on ex_ratatui
- UIBridge protocol (`select`, `confirm`, `input`, `notify`, `set_widget`, `set_status`)
- Interactive mode wired to `planck_agent` event stream
- Theme hot reload via `file_system`
- Prototype TUI app that runs a planck session

### Milestone 4 — Extensions (weeks 10–11)
- Extension loader: source `.ex`, script `.exs`, compiled `ebin/`
- EventBus dispatch with transform/block semantics
- ExtensionAPI: `on`, `register_tool`, `register_command`, `register_shortcut`
- UIBridge callable from extension handlers via message protocol
- At least two example extensions in the repo

### Milestone 5 — Web UI (weeks 12–14)
- `planck_web`: LiveView chat component, streaming via PubSub push
- Session storage via Ecto
- Artifacts panel with sandboxed iframe
- Model/API key management LiveView
- Demo Phoenix app showing planck_web embedded in a regular application

### Milestone 6 — Release (weeks 15–16)
- Burrito packaging, CI cross-platform builds (macOS arm/x86, Linux arm/x86, Windows)
- Hex.pm releases for `planck_ai`, `planck_agent`, `planck_tui`, `planck_web`
- GitHub Releases for `planck` binaries
- Install script
- Comprehensive README + HexDocs

---

## 15. Key Libraries

| Library | Purpose | Source |
|---|---|---|
| `req_llm` | LLM provider HTTP client (18 providers) | hex.pm/packages/req_llm |
| `ex_ratatui` | TUI via Rust ratatui NIFs, precompiled | github.com/mcass19/ex_ratatui |
| `burrito` | Self-contained binary packaging | github.com/burrito-elixir/burrito |
| `phoenix_live_view` | Web UI real-time streaming | hex.pm/packages/phoenix_live_view |
| `ecto_sqlite3` | Session persistence | hex.pm/packages/ecto_sqlite3 |
| `file_system` | Theme/config hot-reload (inotify/FSEvents) | hex.pm/packages/file_system |
| `yaml_elixir` | Config and YAML frontmatter parsing | hex.pm/packages/yaml_elixir |
| `optimus` | CLI argument parsing | hex.pm/packages/optimus |
| `jason` | JSON encode/decode | hex.pm/packages/jason |
