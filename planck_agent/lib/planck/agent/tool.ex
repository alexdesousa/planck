defmodule Planck.Agent.Tool do
  @moduledoc """
  An executable tool for use in agent turns.

  Extends `Planck.AI.Tool` with an `execute_fn` — the function called when the
  LLM requests a tool invocation. The AI tool schema (name, description, parameters)
  is extracted when building `Planck.AI.Context`; `execute_fn` stays agent-side.
  """

  @typedoc """
  A UI side effect attached to a tool result — see `execute_fn`'s 3-element
  return form. Deliberately not just "the widget to open": what shows up in
  the chat transcript to represent this side effect is a different thing
  from what the widget itself contains (`c:Planck.Agent.Widget.render/1`), and
  not every UI side effect involves a widget at all.

  - `%{kind: :text, text: text}` — a UI-only note shown in the chat, invisible
    to the LLM, no widget involved.
  - `%{kind: :widget, label: label, widget: widget_id, data: data}` — a button
    in the chat labeled `label` (sidecar-authored and human-readable — the
    tool decides what invites the click; the widget decides what's inside
    once opened). `widget_id` names a `Planck.Agent.Widget` (its `id/0`,
    paired via a `Planck.Agent.Tool`'s `:widget` field). `data` is an opaque
    initial snapshot for that widget's first paint, avoiding a round-trip
    through `render/1` to open it — optional, may be `nil`.

  See `specs/drafts/v0.1.14-spec.md` Section 2 for the full `{:custom, :ui}`
  message design this feeds into.
  """
  @type ui_content ::
          %{kind: :text, text: String.t()}
          | %{kind: :widget, label: String.t(), widget: String.t(), data: term()}

  @typedoc """
  The function invoked when the LLM requests this tool.

  Receives the calling `agent_id`, the tool call `id` (an opaque string from
  the provider, used to correlate results), and `args` (the JSON-decoded
  arguments map).

  Returns one of:

  - `{:ok, result}` — the common case. `result` is placed directly into the
    model's context as tool result text.
  - `{:ok, result, %{ui: ui_content()}}` — same, plus a UI side effect
    invisible to the model. The third element is a **map**, not a keyword
    list. The `%{ui: ...}` wrapper is stripped before the text reaches the
    LLM — see `Planck.Agent`'s tool-result handling.
  - `{:error, reason}` — `reason` is placed into the model's context the same
    way `result` would be.

  All text values must be strings. Exceptions and exit signals are caught by
  the agent and converted to error strings automatically.
  """
  @type execute_fn ::
          (agent_id :: String.t(), id :: String.t(), args :: map() ->
             {:ok, String.t()}
             | {:ok, String.t(), %{ui: ui_content()}}
             | {:error, String.t()})

  @typedoc """
  A fully-specified tool: schema fields understood by the LLM plus the
  `execute_fn` that runs when the model calls it.

  - `:name` — identifier the model uses to call the tool; must be unique within
    an agent's tool set
  - `:description` — natural-language description sent to the model; quality
    here directly affects how reliably the model uses the tool
  - `:parameters` — JSON Schema object describing the accepted arguments
  - `:execute_fn` — the function called with the agent id, tool call id, and decoded args
  - `:widget` — optional module implementing `Planck.Agent.Widget`, pairing this
    tool with a UI widget. `nil` for most tools. See `Planck.Agent.Sidecar.list_widgets/0`,
    which derives the sidecar's widget list from tools that set this field.
  """
  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameters: map(),
          execute_fn: execute_fn(),
          widget: module() | nil
        }

  @enforce_keys [:name, :description, :parameters, :execute_fn]
  defstruct [:name, :description, :parameters, :execute_fn, :widget]

  @doc """
  Build a `Planck.Agent.Tool` from keyword options.

  ## Examples

      iex> Tool.new(
      ...>   name: "read_file",
      ...>   description: "Read a file",
      ...>   parameters: %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}, "required" => ["path"]},
      ...>   execute_fn: fn _agent_id, _id, %{"path" => path} -> File.read(path) end
      ...> )
      %Planck.Agent.Tool{name: "read_file", ...}
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      name: opts[:name],
      description: opts[:description],
      parameters: opts[:parameters],
      execute_fn: opts[:execute_fn],
      widget: opts[:widget]
    }
  end

  @doc """
  Validate `args` against the tool's JSON schema using `ExJsonSchema`.

  Returns `:ok` or `{:error, message}` suitable for returning directly from an
  `execute_fn`. Called automatically by the agent before invoking `execute_fn`,
  so individual tools do not need to duplicate this check.
  """
  @spec validate_args(t(), map()) :: :ok | {:error, String.t()}
  def validate_args(%__MODULE__{parameters: params}, args) do
    schema = ExJsonSchema.Schema.resolve(params)

    case ExJsonSchema.Validator.validate(schema, args) do
      :ok -> :ok
      {:error, errors} -> {:error, format_schema_errors(errors, params)}
    end
  end

  @spec format_schema_errors([{String.t(), String.t()}], map()) :: String.t()
  defp format_schema_errors(errors, params) do
    properties = get_in(params, ["properties"]) || %{}

    Enum.map_join(errors, " ", fn {message, path} ->
      format_schema_error(message, path, properties)
    end)
  end

  @spec format_schema_error(String.t(), String.t(), map()) :: String.t()
  defp format_schema_error(message, "#", _properties), do: message

  defp format_schema_error("Value is not allowed in enum.", "#/" <> key, properties) do
    case get_in(properties, [key, "enum"]) do
      [_ | _] = values ->
        "#{key}: invalid value. Must be one of: #{Enum.join(values, ", ")}."

      _ ->
        "#{key}: value not allowed."
    end
  end

  defp format_schema_error(message, "#/" <> key, _properties) do
    "#{key}: #{message}"
  end

  @doc """
  Convert to a `Planck.AI.Tool` for use in `Planck.AI.Context` (drops `execute_fn`).
  """
  @spec to_ai_tool(t()) :: Planck.AI.Tool.t()
  def to_ai_tool(%__MODULE__{} = tool) do
    alias Planck.AI.Tool, as: AITool

    AITool.new(
      name: tool.name,
      description: tool.description,
      parameters: tool.parameters
    )
  end
end
