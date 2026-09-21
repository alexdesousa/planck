defmodule PlanckTestSidecar.Compactor do
  use Planck.Agent.Hooks.Compactor

  @impl true
  def compact?(_state, _context, _recent), do: true

  @impl true
  def compact(_state, _context, recent) do
    summary = Planck.Agent.Message.new({:custom, :summary}, [{:text, "Test summary."}])
    kept = Enum.take(recent, -3)
    {:compact, summary, kept}
  end

  @impl true
  def compact_timeout, do: 10_000
end
