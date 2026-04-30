defmodule Planck.Web.Router do
  use Planck.Web, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {Planck.Web.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(Planck.Web.Locale.Plug, gettext: Planck.Web.Gettext, locales: ["en", "es"])
  end

  scope "/", Planck.Web do
    pipe_through(:browser)

    live("/", SessionLive)
  end
end
