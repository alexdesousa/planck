defmodule Planck.AI.ReqLLMBehaviour do
  @moduledoc """
  Behaviour wrapping the `req_llm` streaming call.

  Exists so that `Planck.AI.Adapter` can be tested without making real HTTP
  requests. In production, `Planck.AI.ReqLLM` delegates directly to
  `ReqLLM.stream_text/3`. In tests, `Planck.AI.MockReqLLM` is injected via
  application config.
  """

  @callback stream_text(model_spec :: term(), messages :: term(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}
end

defmodule Planck.AI.ReqLLM do
  @moduledoc false

  @behaviour Planck.AI.ReqLLMBehaviour

  @impl true
  def stream_text(model_spec, messages, opts) do
    ReqLLM.stream_text(model_spec, messages, opts)
  end
end
