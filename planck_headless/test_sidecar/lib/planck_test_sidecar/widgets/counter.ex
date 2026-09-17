defmodule PlanckTestSidecar.Widgets.Counter do
  @moduledoc """
  A minimal widget fixture for integration tests — no Phoenix dependency,
  since `render/1`'s return value is opaque to `planck_agent`/`planck_headless`
  and only the WebUI is expected to interpret it as markup.
  """

  @behaviour Planck.Agent.Widget

  @impl true
  def id, do: "counter"

  @impl true
  def render(myself), do: "count=#{count()} myself=#{inspect(myself)}"

  @impl true
  def handle_action("increment", _args) do
    :persistent_term.put(__MODULE__, count() + 1)
    :ok
  end

  def handle_action("boom", _args), do: {:error, "intentional"}

  @spec count() :: non_neg_integer()
  defp count, do: :persistent_term.get(__MODULE__, 0)
end
