defmodule Planck.Agent.ToolRunner do
  @moduledoc """
  Tracks in-flight tool executions and accumulates their results.

  Created at the start of a tool-execution phase and consumed when all
  tools have reported back. Reset to empty at the end of each turn.
  """

  @typedoc """
  - `:running` — map of `call_id => %{name: name, pid: pid}` for in-flight tools
  - `:results` — accumulated `{call_id, result}` pairs as tools complete
  """
  @type t :: %__MODULE__{
          running: %{String.t() => %{name: String.t(), pid: pid()}},
          results: list()
        }

  defstruct running: %{}, results: []

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
end
