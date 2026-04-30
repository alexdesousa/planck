defmodule PlanckTestSidecar.Compactor do
  use Planck.Agent.Compactor

  @impl true
  def compact(_model, messages) do
    summary = Planck.Agent.Message.new({:custom, :summary}, [{:text, "Test summary."}])
    kept = Enum.take(messages, -3)
    {:compact, summary, kept}
  end

  @impl true
  def compact_timeout, do: 10_000
end
