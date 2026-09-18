defmodule Sidecar.Planck do
  @moduledoc "Sidecar entry point — registers the default set of tools with planck_headless."

  use Planck.Agent.Sidecar

  @impl true
  def tools do
    [
      Sidecar.Tools.Read.tool(),
      Sidecar.Tools.SearchWorkspace.tool(),
      Sidecar.Tools.SessionSearch.tool(),
      Sidecar.Tools.UpdateMemory.tool(),
      Sidecar.Tools.SearchWeb.tool(),
      Sidecar.Tools.WebFetch.tool(),
      Sidecar.Tools.BeadsReady.tool(),
      Sidecar.Tools.BeadsGet.tool(),
      Sidecar.Tools.BeadsDone.tool(),
      Sidecar.Tools.BeadsClaim.tool(),
      Sidecar.Tools.BeadsCreate.tool(),
      Sidecar.Tools.BeadsDelete.tool()
    ]
  end
end
