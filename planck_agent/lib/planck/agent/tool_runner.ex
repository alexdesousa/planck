defmodule Planck.Agent.ToolRunner do
  @moduledoc """
  Tracks in-flight tool executions and handles the full tool execution pipeline:
  resolution, argument validation, safe execution, and loop detection.

  `loop_counts` persists across tool batches within the same user turn and
  resets when a new user turn begins (`do_run_llm` with `:new_turn`).
  """

  alias Planck.Agent.Tool

  @loop_threshold 3

  @typedoc """
  - `:running` — map of `call_id => %{name: name, pid: pid}` for in-flight tools
  - `:results` — accumulated `{call_id, result}` pairs as tools complete
  - `:loop_counts` — consecutive call counts keyed by `{tool_name, args_hash}`;
    persists across tool batches within a user turn, reset on new turns
  """
  @type t :: %__MODULE__{
          running: %{String.t() => %{name: String.t(), pid: pid()}},
          results: list(),
          loop_counts: %{optional({String.t(), non_neg_integer()}) => non_neg_integer()}
        }

  defstruct running: %{}, results: [], loop_counts: %{}

  @doc "Return an empty runner."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Register a set of running tool tasks."
  @spec start([{String.t(), String.t(), pid()}]) :: t()
  def start(entries)

  def start(entries) when is_list(entries) do
    running = Map.new(entries, fn {id, name, pid} -> {id, %{name: name, pid: pid}} end)
    %__MODULE__{running: running}
  end

  @doc """
  Start a new tool batch while preserving `loop_counts` from the previous batch.

  Used for tool continuations within the same user turn so loop detection
  accumulates across multiple LLM rounds.
  """
  @spec next_batch(t(), [{String.t(), String.t(), pid()}]) :: t()
  def next_batch(runner, entries) do
    running = Map.new(entries, fn {id, name, pid} -> {id, %{name: name, pid: pid}} end)
    %{runner | running: running, results: []}
  end

  @doc """
  Resolve, wrap, and track a tool call. Returns `{updated_runner, wrapped_fn}`.

  Looks up the tool by name, records the call for loop detection, and returns
  a zero-arg closure that:
  - Validates arguments against the tool schema
  - Executes safely, catching all exceptions and normalising them to strings
  - Appends a loop nudge to binary results when consecutive identical calls
    reach `@loop_threshold`
  """
  @spec prepare_call(
          t(),
          %{String.t() => Tool.t()},
          String.t(),
          String.t(),
          String.t(),
          map()
        ) :: {t(), (-> {:ok, String.t()} | {:error, term()})}
  def prepare_call(runner, tools, agent_id, name, call_id, args)

  def prepare_call(runner, tools, agent_id, name, call_id, args) do
    key = {name, :erlang.phash2(args)}
    count = Map.get(runner.loop_counts, key, 0) + 1
    runner = %{runner | loop_counts: Map.put(runner.loop_counts, key, count)}

    execute_fn =
      case Map.get(tools, name) do
        nil -> fn -> {:error, "unknown tool: #{name}"} end
        %Tool{} = tool -> fn -> run_tool(tool, agent_id, call_id, args) end
      end

    wrapped = fn ->
      execute_fn.()
      |> maybe_append_loop_nudge(name, count)
    end

    {runner, wrapped}
  end

  @doc """
  Mark a tool call as done.

  Returns `{:ok, updated_runner}` or `:not_running` when `call_id` is not
  in the running set (stale result after an abort).
  """
  @spec mark_done(t(), String.t(), term()) :: {:ok, t()} | :not_running
  def mark_done(runner, call_id, result)

  def mark_done(%__MODULE__{running: running, results: results} = runner, call_id, result) do
    case Map.pop(running, call_id) do
      {nil, _} ->
        :not_running

      {_, remaining} ->
        {:ok, %{runner | running: remaining, results: [{call_id, result} | results]}}
    end
  end

  @doc "Return `true` when all tool calls have completed."
  @spec done?(t()) :: boolean()
  def done?(runner)

  def done?(%__MODULE__{running: running}), do: map_size(running) == 0

  @doc "Kill all in-flight tool task processes."
  @spec cancel_all(t()) :: :ok
  def cancel_all(runner)

  def cancel_all(%__MODULE__{running: running}) do
    Enum.each(running, fn {_id, %{pid: pid}} -> Process.exit(pid, :kill) end)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec run_tool(Tool.t(), String.t(), String.t(), map()) ::
          {:ok, String.t()}
          | {:error, String.t()}
  defp run_tool(tool, agent_id, call_id, args)

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
        when result: {:ok, String.t()} | {:error, String.t()}
  defp maybe_append_loop_nudge(result, name, count)

  defp maybe_append_loop_nudge({:ok, result}, name, count)
       when is_binary(result) and is_binary(name) and count >= @loop_threshold do
    nudge =
      "\n\n> Note: you have called `#{name}` with identical arguments #{count} times " <>
        "this turn and received the same result. If you need different information, " <>
        "consider changing your arguments or trying a different approach."

    {:ok, result <> nudge}
  end

  defp maybe_append_loop_nudge(result, _name, _count) do
    result
  end
end
