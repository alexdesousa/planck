defmodule Planck.Agent.Usage do
  @moduledoc """
  Accumulated token usage and cost for an agent session.

  Updated after every LLM turn via `add_turn/4`. Cost is computed from the
  model's per-token rates and accumulated alongside token counts — it never
  decreases, even when messages are rewound.
  """

  @typedoc """
  - `:input_tokens` — total input tokens consumed this session
  - `:output_tokens` — total output tokens consumed this session
  - `:cost` — total cost in USD this session
  """
  @type t :: %__MODULE__{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cost: float()
        }

  defstruct input_tokens: 0, output_tokens: 0, cost: 0.0

  @doc "Return a zeroed usage struct."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Build a `Usage` struct from agent start-up keyword options.

  Reads `:usage` (a map with `:input_tokens` and `:output_tokens`) and `:cost`
  to seed the struct when resuming a previous session.
  """
  @spec from_opts(keyword()) :: t()
  def from_opts(opts) do
    prior = Keyword.get(opts, :usage) || %{}

    %__MODULE__{
      input_tokens: prior[:input_tokens] || 0,
      output_tokens: prior[:output_tokens] || 0,
      cost: Keyword.get(opts, :cost, 0.0)
    }
  end

  @doc """
  Add one turn's token counts and compute its cost from `model`.

  Returns the updated struct. The per-turn cost is calculated from the model's
  `cost.input` and `cost.output` rates (per million tokens). When the model has
  no cost information the cost field is left unchanged.
  """
  @spec add_turn(t(), non_neg_integer(), non_neg_integer(), term()) :: t()
  def add_turn(usage, input, output, model)

  def add_turn(%__MODULE__{} = usage, input, output, model) do
    turn_cost =
      case model do
        %{cost: %{input: in_rate, output: out_rate}} ->
          (input * in_rate + output * out_rate) / 1_000_000

        _ ->
          0.0
      end

    %{
      usage
      | input_tokens: usage.input_tokens + input,
        output_tokens: usage.output_tokens + output,
        cost: usage.cost + turn_cost
    }
  end
end
