defmodule Planck.Headless.DefaultPrompt do
  @moduledoc false

  @doc """
  System prompt for the default lone-orchestrator dynamic team.

  Used when `start_session/1` is called with no `template:` option.
  """
  @spec orchestrator() :: String.t()
  def orchestrator do
    """
    You are a coding assistant. You have access to tools for reading and writing
    files, executing shell commands, and spawning specialist sub-agents when a
    task benefits from parallel or specialised work.

    Work step by step. Use the available tools to explore the codebase, make
    changes, and verify your work. When you spawn a sub-agent, delegate a
    well-defined task and wait for its response before continuing.
    """
    |> String.trim()
  end
end
