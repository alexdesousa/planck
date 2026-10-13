defmodule Planck.Agent.Turn do
  @moduledoc """
  Turn state for a running agent.

  Holds the streaming status, in-flight stream task, and the dissolved fields
  from `TurnState` (index, checkpoints), `StreamBuffer` (text, thinking, calls),
  and `ToolRunner` (running, results).
  """

  alias Planck.Agent.{Context, Hooks, Identity, Message, Tool}
  alias Planck.Agent.Hooks.ToolStart

  @typedoc "Status of the turn"
  @type status :: :idle | :streaming | :executing_tools

  @typedoc """
  A tool call.
  """
  @type tool_call :: %{
          id: String.t(),
          name: String.t(),
          args: map()
        }

  @typedoc """
  An in-flight tool call tracked in `running`.
  """
  @type running_entry :: %{
          id: String.t(),
          tool_call: tool_call(),
          function: (any() -> tool_result()),
          approved: boolean(),
          pid: nil | pid(),
          metadata: %{
            optional(:reason) => String.t(),
            optional(:kind) => :deny | :await_approval
          }
        }

  @typedoc """
  The outcome of a single tool call after the full pipeline
  (validate → gate → execute → transform).

  - `{:ok, text}` — success; `text` is placed into the model's context
    as the tool result.
  - `{:ok, text, %{ui: ui}}` — success plus a UI side effect. `text`
    goes to the model; `ui` (`t:Planck.Agent.Tool.ui_content/0`) is
    stripped before the text reaches the LLM and persisted as a sibling
    `{:custom, :ui}` message (see `Planck.Agent`'s tool-result handling).
    Produced by `execute_fn` directly or attached by a `ToolEnd` hook.
  - `{:error, reason}` — failure; rendered as `"Error: <reason>"` for the
    model (non-string reasons are inspected). Produced by `execute_fn`,
    argument validation, unknown tools, or a `ToolStart` denial.
  - `{:error, reason, %{ui: ui}}` — failure plus a UI side effect (e.g. an
    approval widget served with a blocked call). The text still reaches
    the model; the UI side effect is extracted exactly like the ok
    triple. Produced by a `ToolStart` denial carrying UI or attached by a
    `ToolEnd` hook.

  The third element, when present, is always a map with a `:ui` key —
  never a keyword list.
  """
  @type tool_result ::
          {:ok, String.t()}
          | {:ok, String.t(), %{ui: Tool.ui_content()}}
          | {:error, term()}
          | {:error, term(), %{ui: Tool.ui_content()}}

  @typedoc """
  Result entry.
  """
  @type result_entry :: %{
          call: running_entry(),
          result: tool_result()
        }

  @typedoc """
  Turn information.
  """
  @type t :: %__MODULE__{
          status: status(),
          stream_task: pid() | nil,
          stream_ref: reference() | nil,
          stream_start: non_neg_integer(),
          index: non_neg_integer(),
          checkpoints: [non_neg_integer()],
          buffer_text: String.t(),
          buffer_thinking: String.t(),
          buffer_calls: [map()],
          running: %{String.t() => running_entry()},
          results: [{String.t(), result_entry()}]
        }

  @doc false
  defstruct status: :idle,
            stream_task: nil,
            stream_ref: nil,
            stream_start: 0,
            index: 0,
            checkpoints: [],
            buffer_text: "",
            buffer_thinking: "",
            buffer_calls: [],
            running: %{},
            results: []

  @doc "Return a fresh turn state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Updates turn to start.
  """
  @spec start_turn(t(), pid(), reference(), [Message.t()]) :: t()
  def start_turn(turn, pid, reference, messages)

  def start_turn(%__MODULE__{} = turn, pid, reference, messages)
      when is_pid(pid) and is_reference(reference) and is_list(messages) do
    %{
      turn
      | index: turn.index + 1,
        stream_task: pid,
        stream_ref: reference,
        stream_start: length(messages),
        status: :streaming,
        results: [],
        running: %{}
    }
  end

  @doc """
  Updates turn to continuation.
  """
  @spec continue_turn(t(), pid(), reference()) :: t()
  def continue_turn(turn, pid, reference)

  def continue_turn(%__MODULE__{} = turn, pid, reference)
      when is_pid(pid) and is_reference(reference) do
    %{
      turn
      | stream_task: pid,
        stream_ref: reference,
        status: :streaming,
        results: [],
        running: %{}
    }
  end

  @doc "Push a checkpoint (current message-list length) onto the stack."
  @spec push_checkpoint(t(), [Message.t()]) :: t()
  def push_checkpoint(turn, messages)

  def push_checkpoint(%__MODULE__{} = turn, messages)
      when is_list(messages) do
    length = length(messages)
    %{turn | checkpoints: [length | turn.checkpoints], status: :streaming}
  end

  @doc "Rebuild checkpoints from a message list, preserving the current index."
  @spec rebuild_checkpoints(t(), [Message.t()]) :: t()
  def rebuild_checkpoints(%__MODULE__{} = turn, messages) do
    checkpoints =
      messages
      |> Enum.with_index()
      |> Enum.filter(fn {msg, _} -> msg.role == :user end)
      |> Enum.map(fn {_, idx} -> idx end)
      |> Enum.reverse()

    %{turn | checkpoints: checkpoints}
  end

  @doc "Append a text delta to the stream buffer."
  @spec append_text(t(), String.t()) :: t()
  def append_text(turn, text)

  def append_text(%__MODULE__{} = turn, text) when is_binary(text) do
    %{turn | buffer_text: turn.buffer_text <> text}
  end

  @doc "Append a thinking delta to the stream buffer."
  @spec append_thinking(t(), String.t()) :: t()
  def append_thinking(turn, text)

  def append_thinking(%__MODULE__{} = turn, text) when is_binary(text) do
    %{turn | buffer_thinking: turn.buffer_thinking <> text}
  end

  @doc "Add a completed tool call to the stream buffer."
  @spec append_call(t(), map()) :: t()
  def append_call(turn, call)

  def append_call(%__MODULE__{} = turn, call) when is_map(call) do
    %{turn | buffer_calls: turn.buffer_calls ++ [call]}
  end

  @doc """
  Resolves, wraps and tracks the buffered tool calls.
  """
  @spec prepare_calls(t(), Identity.t(), Context.t(), Hooks.t()) :: t()
  def prepare_calls(turn, identity, context, hooks)

  def prepare_calls(
        %__MODULE__{} = turn,
        %Identity{} = identity,
        %Context{} = context,
        %Hooks{} = hooks
      ) do
    tool_calls = turn.buffer_calls
    turn = %{turn | buffer_calls: []}

    Enum.reduce(tool_calls, turn, fn tool_call, %__MODULE__{} = turn ->
      prepare_call(turn, identity, context, hooks, tool_call)
    end)
  end

  @doc "List parked tool calls as `running_entry` maps, for UI consumption."
  @spec list_pending(t()) :: [running_entry()]
  def list_pending(turn)

  def list_pending(%__MODULE__{running: running}) do
    running
    |> Stream.filter(fn
      {_call_id, %{approved: false, pid: nil}} -> true
      _ -> false
    end)
    |> Enum.map(&elem(&1, 1))
  end

  @doc """
  Approves a tool call.
  """
  @spec approve_pending(t(), String.t()) ::
          {:ok, {running_entry(), t()}}
          | {:error, :not_found}
  def approve_pending(turn, call_id)

  def approve_pending(%__MODULE__{} = turn, call_id)
      when is_binary(call_id) do
    case Map.get(turn.running, call_id) do
      %{approved: false, pid: nil} = entry ->
        entry = %{entry | approved: true, metadata: %{}}
        running = Map.put(turn.running, call_id, entry)
        turn = %{turn | running: running}

        {:ok, {entry, turn}}

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Denies a tool call.
  """
  @spec deny_pending(t(), String.t(), String.t()) ::
          {:ok, {running_entry(), t()}}
          | {:error, :not_found}
  def deny_pending(turn, call_id, reason)

  def deny_pending(%__MODULE__{} = turn, call_id, reason)
      when is_binary(call_id) and is_binary(reason) do
    case Map.get(turn.running, call_id) do
      %{approved: false, pid: nil} = entry ->
        metadata = %{reason: reason, kind: :deny}
        entry = %{entry | approved: true, metadata: metadata}

        running = Map.put(turn.running, call_id, entry)
        turn = %{turn | running: running}

        {:ok, {entry, turn}}

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Register running tool calls.
  """
  @spec register_running(t(), String.t(), pid()) :: t()
  def register_running(turn, call_id, pid)

  def register_running(%__MODULE__{} = turn, call_id, pid)
      when is_binary(call_id) and is_pid(pid) do
    case Map.get(turn.running, call_id) do
      %{pid: nil} = entry ->
        entry = %{entry | approved: true, pid: pid}
        running = Map.put(turn.running, call_id, entry)
        %{turn | running: running}

      _ ->
        turn
    end
  end

  @doc "Mark a tool call as done. Returns `{:ok, updated_turn}` or `:not_running`."
  @spec mark_tool_done(t(), String.t(), tool_result()) ::
          {:ok, t()}
          | {:error, :not_running}
  def mark_tool_done(turn, call_id, result)

  def mark_tool_done(%__MODULE__{running: running, results: results} = turn, call_id, result) do
    case Map.pop(running, call_id) do
      {nil, _} ->
        {:error, :not_running}

      {entry, remaining} ->
        result = %{call: %{entry | pid: nil}, result: result}
        results = results ++ [{call_id, result}]

        {:ok, %{turn | running: remaining, results: results}}
    end
  end

  @doc "Return `true` when all tool calls have completed."
  @spec tool_done?(t()) :: boolean()
  def tool_done?(turn)

  def tool_done?(%__MODULE__{running: running}) do
    map_size(running) == 0
  end

  @doc """
  Aborts the whole turn resetting the stream.
  """
  @spec abort(t()) :: t()
  def abort(turn)

  def abort(%__MODULE__{} = turn) do
    if is_pid(turn.stream_task) do
      Task.Supervisor.terminate_child(Planck.Agent.TaskSupervisor, turn.stream_task)
    end

    Enum.each(turn.running, fn
      {_id, %{pid: pid}} when is_pid(pid) ->
        Process.exit(pid, :kill)

      {_id, _parked} ->
        :ok
    end)

    reset_streaming(turn)
  end

  @doc "Reset the stream buffer and tool runner to their initial state."
  @spec reset_streaming(t()) :: t()
  @spec reset_streaming(t(), keyword()) :: t()
  def reset_streaming(turn, options \\ [])

  def reset_streaming(%__MODULE__{} = turn, options) do
    turn =
      %{
        turn
        | status: :idle,
          stream_task: nil,
          stream_ref: nil,
          buffer_text: "",
          buffer_thinking: "",
          running: %{},
          results: []
      }

    if options[:include_calls] do
      %{turn | buffer_calls: []}
    else
      turn
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec prepare_call(t(), Identity.t(), Context.t(), Hooks.t(), tool_call()) :: t()
  defp prepare_call(turn, identity, context, hooks, tool_call)

  defp prepare_call(
         %__MODULE__{} = turn,
         %Identity{} = identity,
         %Context{} = ctx,
         %Hooks{} = hooks,
         tool_call
       )
       when is_map(tool_call) do
    unknown_tool_error = {:error, "unknown tool: #{tool_call.name}"}

    with %Tool{} = tool <- Map.get(ctx.tools, tool_call.name, unknown_tool_error),
         :ok <- Tool.validate_args(tool, tool_call.args) do
      do_prepare_call(turn, identity, hooks, tool, tool_call)
    else
      {:error, _} = error ->
        fun = fn _ -> apply_transform(error, identity, hooks, tool_call) end
        register_call(turn, tool_call, fun)
    end
  end

  @spec do_prepare_call(t(), Identity.t(), Hooks.t(), Tool.t(), tool_call()) :: t()
  defp do_prepare_call(turn, identity, hooks, tool, tool_call)

  defp do_prepare_call(
         %__MODULE__{} = turn,
         %Identity{} = identity,
         %Hooks{} = hooks,
         %Tool{} = tool,
         tool_call
       )
       when is_map(tool_call) do
    approved_fn = fn _ ->
      identity
      |> run_tool(tool, tool_call)
      |> apply_transform(identity, hooks, tool_call)
    end

    denied_fn = fn reason when is_binary(reason) ->
      reason
      |> ToolStart.blocked_error()
      |> apply_transform(identity, hooks, tool_call)
    end

    case run_gate(identity, hooks, tool_call) do
      :ok ->
        register_call(turn, tool_call, approved_fn)

      {:deny, reason} ->
        metadata = %{reason: reason, kind: :deny}
        register_call(turn, tool_call, denied_fn, metadata: metadata)

      {:await_approval, reason} ->
        fun = fn
          reason when is_binary(reason) -> denied_fn.(reason)
          other -> approved_fn.(other)
        end

        metadata = %{reason: reason, kind: :await_approval}

        register_call(turn, tool_call, fun,
          run?: false,
          metadata: metadata
        )
    end
  end

  @spec run_gate(Identity.t(), Hooks.t(), tool_call()) :: ToolStart.gate_result()
  defp run_gate(identity, hooks, tool_call)

  defp run_gate(%Identity{} = _identity, %Hooks{tool_start: nil}, _tool_call) do
    :ok
  end

  defp run_gate(%Identity{} = identity, %Hooks{} = hooks, tool_call)
       when is_map(tool_call) do
    Hooks.ToolStart.proceed(
      hooks.tool_start,
      identity.id,
      tool_call.name,
      tool_call.args,
      hooks.sidecar_node
    )
  end

  @spec apply_transform(tool_result(), Identity.t(), Hooks.t(), tool_call()) :: tool_result()
  defp apply_transform(result, identity, hooks, tool_call)

  defp apply_transform(result, %Identity{} = _identity, %Hooks{tool_end: nil}, _tool_call) do
    result
  end

  defp apply_transform(result, %Identity{} = identity, %Hooks{} = hooks, tool_call)
       when is_map(tool_call) do
    Hooks.ToolEnd.transform(
      hooks.tool_end,
      identity.id,
      tool_call.name,
      tool_call.args,
      result,
      hooks.sidecar_node
    )
  end

  @spec run_tool(Identity.t(), Tool.t(), tool_call()) ::
          {:ok, String.t()}
          | {:ok, String.t(), %{ui: Tool.ui_content()}}
          | {:error, String.t()}
          | {:error, String.t(), %{ui: Tool.ui_content()}}
  defp run_tool(identity, tool, tool_call)

  defp run_tool(%Identity{} = identity, %Tool{} = tool, tool_call)
       when is_map(tool_call) do
    tool.execute_fn.(identity.id, tool_call.id, tool_call.args)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  @spec register_call(t(), tool_call(), (any() -> tool_result())) :: t()
  @spec register_call(t(), tool_call(), (any() -> tool_result()), keyword()) :: t()
  def register_call(turn, tool_call, tool_call_fn, options \\ [])

  def register_call(%__MODULE__{} = turn, tool_call, tool_call_fn, options)
      when is_map(tool_call) and
             is_function(tool_call_fn, 1) and
             is_list(options) do
    entry = %{
      tool_call: tool_call,
      function: tool_call_fn,
      approved: Keyword.get(options, :run?, true),
      metadata: options[:metadata] || %{},
      pid: nil
    }

    running = Map.put(turn.running, tool_call.id, entry)

    %{turn | running: running, results: [], status: :executing_tools}
  end
end
