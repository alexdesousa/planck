defmodule Planck.Headless do
  @moduledoc """
  The headless core of the Planck coding agent.

  `planck_headless` is a long-running OTP application that owns configuration,
  loads resources at startup (tools, skills, teams, compactor), and manages
  session lifecycles. UIs (`planck_tui`, `planck_web`) depend on this module;
  they are rendering surfaces only.

  See `specs/planck-headless.md` for the full design.

  ## Current status

  Phase 1A in progress — the package scaffolds the mix project and
  `Planck.Headless.Config`. The session lifecycle, ResourceStore, and team
  registry APIs in the spec land in subsequent phases.
  """

  alias Planck.Headless.Config

  @doc """
  Return the resolved configuration.
  """
  @spec config() :: Config.t()
  def config, do: Config.get()
end
