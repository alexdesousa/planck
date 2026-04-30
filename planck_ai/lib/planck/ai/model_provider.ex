defmodule Planck.AI.ModelProvider do
  @moduledoc """
  Behaviour for modules that supply a list of `Planck.AI.Model` structs.

  ## Cloud providers (Anthropic, OpenAI, Google)

  These source their catalog from LLMDB, a bundled snapshot of the public model
  registry. No network call is made at query time — the data is loaded from the
  package artifact into `:persistent_term` on first access.

  ## Local providers (Ollama, llama.cpp)

  These fetch the model list from the running local server at call time, so the
  returned list reflects whatever models are currently loaded.

  ## Error handling

  All implementations must return `[]` on any failure — they must never raise.
  """

  alias Planck.AI.Model

  @callback all(keyword()) :: [Model.t()]
end
