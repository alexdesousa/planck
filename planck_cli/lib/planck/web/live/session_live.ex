defmodule Planck.Web.SessionLive do
  use Planck.Web, :live_view

  def render(assigns) do
    ~H"""
    <div class="flex items-center justify-center h-screen">
      <p class="font-mono text-muted-foreground">Planck Web UI — coming soon</p>
    </div>
    """
  end
end
