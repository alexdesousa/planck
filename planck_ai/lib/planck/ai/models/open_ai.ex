defmodule Planck.AI.Models.OpenAI do
  @moduledoc """
  Model catalog for OpenAI's GPT family, sourced from LLMDB.

  Requires the `OPENAI_API_KEY` environment variable (or pass `api_key:` in opts).
  """

  @behaviour Planck.AI.ModelProvider

  alias Planck.AI.LLMDB

  @spec all() :: [Planck.AI.Model.t()]
  @spec all(keyword()) :: [Planck.AI.Model.t()]
  @impl Planck.AI.ModelProvider
  def all(_opts \\ []), do: LLMDB.models(:openai)
end
