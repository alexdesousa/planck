defmodule Planck.Agent.EExRenderer do
  @moduledoc """
  Shared EEx template renderer for custom command bodies and the compactor's
  delegate system prompt.

  Templates are stored as raw strings (e.g. the body of a `COMMAND.md` file or
  the built-in compactor's `@delegate_system_prompt`) and rendered on demand
  with a keyword list of bindings. Unbound variables raise — they indicate a
  template referencing a binding the caller didn't supply.
  """

  @doc """
  Render an EEx template string with the given bindings.

  `bindings` is a keyword list (e.g. `[args: "src/auth", prompt: nil]`).
  Variables referenced in the template that are not in `bindings` raise
  `KeyError` — they are not silently dropped.
  """
  @spec render(String.t(), keyword()) :: String.t()
  def render(template, bindings) when is_binary(template) and is_list(bindings) do
    quoted = EEx.compile_string(template)
    {result, _} = Code.eval_quoted(quoted, bindings)
    result
  end
end
