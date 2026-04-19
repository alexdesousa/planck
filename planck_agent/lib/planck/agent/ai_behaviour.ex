defmodule Planck.Agent.AIBehaviour do
  @moduledoc false

  # Wraps Planck.AI.stream/3 so it can be mocked in tests via Mox.

  @callback stream(Planck.AI.Model.t(), Planck.AI.Context.t(), keyword()) ::
              Enumerable.t(Planck.AI.Stream.t())

  @callback get_model(atom(), String.t()) :: {:ok, Planck.AI.Model.t()} | {:error, :not_found}

  @doc false
  @spec client() :: module()
  def client do
    Application.get_env(:planck_agent, :ai_client, Planck.AI)
  end
end
