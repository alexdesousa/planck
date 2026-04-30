defmodule Planck.AI.Models.Anthropic do
  @moduledoc "Model catalog for Anthropic's Claude family, sourced from LLMDB."

  @behaviour Planck.AI.ModelProvider

  alias Planck.AI.LLMDB

  @spec all() :: [Planck.AI.Model.t()]
  @spec all(keyword()) :: [Planck.AI.Model.t()]
  @impl Planck.AI.ModelProvider
  def all(_opts \\ []), do: LLMDB.models(:anthropic)
end
