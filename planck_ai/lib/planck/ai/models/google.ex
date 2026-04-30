defmodule Planck.AI.Models.Google do
  @moduledoc """
  Model catalog for Google's Gemini family, sourced from LLMDB.

  Requires the `GOOGLE_API_KEY` environment variable (or pass `api_key:` in opts).
  """

  @behaviour Planck.AI.ModelProvider

  alias Planck.AI.LLMDB

  @spec all() :: [Planck.AI.Model.t()]
  @spec all(keyword()) :: [Planck.AI.Model.t()]
  @impl Planck.AI.ModelProvider
  def all(_opts \\ []), do: LLMDB.models(:google)
end
