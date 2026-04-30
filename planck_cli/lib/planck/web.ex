defmodule Planck.Web do
  @moduledoc false

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller, only: [get_csrf_token: 0]
      import Phoenix.HTML

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Planck.Web.Components
      use Gettext, backend: Planck.Web.Gettext

      alias Phoenix.LiveView.JS
      alias Planck.Web.Layouts

      use Phoenix.VerifiedRoutes,
        endpoint: Planck.Web.Endpoint,
        router: Planck.Web.Router,
        statics: Planck.Web.static_paths()
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:json]

      import Plug.Conn

      alias Planck.Headless
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: Planck.Web.Endpoint,
        router: Planck.Web.Router,
        statics: Planck.Web.static_paths()
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
