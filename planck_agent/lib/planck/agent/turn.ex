defmodule Planck.Agent.Turn do
  @moduledoc """
  Turn state for a running agent.

  Holds the streaming status, in-flight stream task, and the dissolved fields
  from `TurnState` (index, checkpoints), `StreamBuffer` (text, thinking, calls),
  and `ToolRunner` (running, results, loop_counts).
  """

  alias Planck.Agent.{Message, Tool}

  @loop_threshold 3

  @typedoc "Status of the turn"
  @type status :: :idle | :streaming | :executing_tools

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
          running: %{String.t() => %{name: String.t(), pid: pid()}},
          results: list(),
          loop_counts: %{optional({String.t(), non_neg_integer()}) => non_neg_integer()}
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
            results: [],
            loop_counts: %{}

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
        running: %{},
        loop_counts: %{}
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
  Resolve, wrap, and track a tool call. Returns `{updated_turn, wrapped_fn}`.
  """
  @spec prepare_call(t(), tools, agent_id, tool_call) :: {t(), (-> result)}
        when tools: %{tool_name => Tool.t()},
             agent_id: String.t(),
             tool_call: %{:id => String.t(), :name => tool_name, args: map()},
             tool_name: String.t(),
             result:
               {:ok, String.t()}
               | {:ok, String.t(), %{ui: Tool.ui_content()}}
               | {:error, term()}
  def prepare_call(turn, tools, agent_id, tool_call)

  def prepare_call(%__MODULE__{} = turn, tools, agent_id, tool_call)
      when is_map(tools) and
             is_binary(agent_id) and
             is_map(tool_call) do
    key = {tool_call.name, :erlang.phash2(tool_call.args)}
    count = Map.get(turn.loop_counts, key, 0) + 1

    turn = %{turn | loop_counts: Map.put(turn.loop_counts, key, count)}

    tool_call_fn =
      case Map.get(tools, tool_call.name) do
        nil ->
          fn ->
            {:error, "unknown tool: #{tool_call.name}"}
          end

        %Tool{} = tool ->
          fn ->
            tool
            |> run_tool(agent_id, tool_call.id, tool_call.args)
            |> maybe_append_loop_nudge(tool_call.name, count)
          end
      end

    {turn, tool_call_fn}
  end

  @doc """
  Registers tool call.
  """
  @spec register_call(t(), tool_call, pid()) :: t()
        when tool_call: %{:id => String.t(), :name => String.t(), args: map()}
  def register_call(turn, tool_call, pid)

  def register_call(%__MODULE__{} = turn, tool_call, pid)
      when is_map(tool_call) and is_pid(pid) do
    entry = %{name: tool_call.name, pid: pid}

    %{
      turn
      | running: Map.put(turn.running, tool_call.id, entry),
        results: [],
        status: :executing_tools
    }
  end

  @doc "Mark a tool call as done. Returns `{:ok, updated_turn}` or `:not_running`."
  @spec mark_tool_done(t(), String.t(), term()) ::
          {:ok, t()}
          | :not_running
  def mark_tool_done(turn, call_id, result)

  def mark_tool_done(%__MODULE__{running: running, results: results} = turn, call_id, result) do
    case Map.pop(running, call_id) do
      {nil, _} ->
        :not_running

      {_, remaining} ->
        {:ok, %{turn | running: remaining, results: [{call_id, result} | results]}}
    end
  end

  @doc "Return `true` when all tool calls have completed."
  @spec tool_done?(t()) :: boolean()
  def tool_done?(turn)

  def tool_done?(%__MODULE__{running: running}) do
    map_size(running) == 0
  end

  @doc "Kill all in-flight tool task processes."
  @spec cancel_all_tools(t()) :: :ok
  def cancel_all_tools(%__MODULE__{running: running}) do
    Enum.each(running, fn {_id, %{pid: pid}} -> Process.exit(pid, :kill) end)
  end

  @doc "Reset the stream buffer and tool runner to their initial state."
  @spec reset_streaming(t()) :: t()
  def reset_streaming(%__MODULE__{} = turn) do
    %{
      turn
      | status: :idle,
        stream_task: nil,
        stream_ref: nil,
        buffer_text: "",
        buffer_thinking: "",
        buffer_calls: [],
        running: %{},
        results: [],
        loop_counts: %{}
    }
  end

  @doc "Cancel the in-flight stream task, if any."
  @spec cancel_stream(t()) :: :ok
  def cancel_stream(turn)

  def cancel_stream(%__MODULE__{stream_task: nil}) do
    :ok
  end

  def cancel_stream(%__MODULE__{stream_task: pid})
      when is_pid(pid) do
    Task.Supervisor.terminate_child(Planck.Agent.TaskSupervisor, pid)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec run_tool(Tool.t(), String.t(), String.t(), map()) ::
          {:ok, String.t()}
          | {:ok, String.t(), %{ui: Tool.ui_content()}}
          | {:error, String.t()}
  defp run_tool(%Tool{} = tool, agent_id, call_id, args) do
    with :ok <- Tool.validate_args(tool, args) do
      tool.execute_fn.(agent_id, call_id, args)
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  @spec maybe_append_loop_nudge(result, String.t(), pos_integer()) :: result
        when result:
               {:ok, String.t()}
               | {:ok, String.t(), %{ui: Tool.ui_content()}}
               | {:error, String.t()}
  defp maybe_append_loop_nudge({:ok, result}, name, count)
       when is_binary(result) and is_binary(name) and count >= @loop_threshold do
    {:ok, result <> loop_nudge(name, count)}
  end

  defp maybe_append_loop_nudge({:ok, result, %{ui: ui}}, name, count)
       when is_binary(result) and is_binary(name) and count >= @loop_threshold do
    {:ok, result <> loop_nudge(name, count), %{ui: ui}}
  end

  defp maybe_append_loop_nudge(result, _name, _count) do
    result
  end

  @spec loop_nudge(String.t(), pos_integer()) :: String.t()
  defp loop_nudge(name, count) do
    "\n\n> Note: you have called `#{name}` with identical arguments #{count} times " <>
      "this turn and received the same result. If you need different information, " <>
      "consider changing your arguments or trying a different approach."
  end
end
