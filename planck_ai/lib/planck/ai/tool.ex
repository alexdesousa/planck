defmodule Planck.AI.Tool do
  @moduledoc """
  Defines a tool that can be called by the model during a conversation.

  The `parameters` field is a JSON Schema map describing the tool's input.

  ## Examples

      iex> Planck.AI.Tool.new(
      ...>   name: "bash",
      ...>   description: "Execute a shell command",
      ...>   parameters: %{
      ...>     "type" => "object",
      ...>     "properties" => %{
      ...>       "command" => %{"type" => "string", "description" => "The command to run"}
      ...>     },
      ...>     "required" => ["command"]
      ...>   }
      ...> )
      %Planck.AI.Tool{name: "bash", description: "Execute a shell command", parameters: %{"type" => "object", "properties" => %{"command" => %{"type" => "string", "description" => "The command to run"}}, "required" => ["command"]}}

  """

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameters: map()
        }

  defstruct [:name, :description, :parameters]

  @doc """
  Builds a `%Planck.AI.Tool{}` struct from keyword options.

  ## Options

  - `:name` — tool name (required)
  - `:description` — human-readable description (required)
  - `:parameters` — JSON Schema map describing the tool's input (required)
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      name: opts[:name],
      description: opts[:description],
      parameters: opts[:parameters]
    }
  end
end
