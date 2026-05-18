defmodule Sidecar.Planck do
  @moduledoc "Sidecar entry point — registers the default set of tools with planck_headless."

  use Planck.Agent.Sidecar

  @impl true
  def tools do
    [
      Sidecar.Tools.Read.tool(),
      Sidecar.Tools.SearchWorkspace.tool(),
      Sidecar.Tools.SearchWeb.tool(),
      Sidecar.Tools.WebFetch.tool()
    ]
  end
end
