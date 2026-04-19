defmodule Planck.Agent.Tool do
  @moduledoc """
  An executable tool for use in agent turns.

  Extends `Planck.AI.Tool` with an `execute_fn` — the function called when the
  LLM requests a tool invocation. The AI tool schema (name, description, parameters)
  is extracted when building `Planck.AI.Context`; `execute_fn` stays agent-side.
  """

  @typedoc """
  The function invoked when the LLM requests this tool.

  Receives the tool call `id` (an opaque string from the provider, used to
  correlate results) and `args` (the JSON-decoded arguments map). Must return
  `{:ok, result}` or `{:error, reason}` where both values are strings — they
  are placed directly into the model's context as tool result text. Exceptions
  and exit signals are caught by the agent and converted to error strings
  automatically.
  """
  @type execute_fn ::
          (id :: String.t(), args :: map() -> {:ok, String.t()} | {:error, String.t()})

  @typedoc """
  A fully-specified tool: schema fields understood by the LLM plus the
  `execute_fn` that runs when the model calls it.

  - `:name` — identifier the model uses to call the tool; must be unique within
    an agent's tool set
  - `:description` — natural-language description sent to the model; quality
    here directly affects how reliably the model uses the tool
  - `:parameters` — JSON Schema object describing the accepted arguments
  - `:execute_fn` — the function called with the tool call id and decoded args
  """
  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameters: map(),
          execute_fn: execute_fn()
        }

  @enforce_keys [:name, :description, :parameters, :execute_fn]
  defstruct [:name, :description, :parameters, :execute_fn]

  @doc """
  Build a `Planck.Agent.Tool` from keyword options.

  ## Examples

      iex> Tool.new(
      ...>   name: "read_file",
      ...>   description: "Read a file",
      ...>   parameters: %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}, "required" => ["path"]},
      ...>   execute_fn: fn _id, %{"path" => path} -> File.read(path) end
      ...> )
      %Planck.Agent.Tool{name: "read_file", ...}
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      name: opts[:name],
      description: opts[:description],
      parameters: opts[:parameters],
      execute_fn: opts[:execute_fn]
    }
  end

  @doc """
  Convert to a `Planck.AI.Tool` for use in `Planck.AI.Context` (drops `execute_fn`).
  """
  @spec to_ai_tool(t()) :: Planck.AI.Tool.t()
  def to_ai_tool(%__MODULE__{} = tool) do
    Planck.AI.Tool.new(
      name: tool.name,
      description: tool.description,
      parameters: tool.parameters
    )
  end
end
