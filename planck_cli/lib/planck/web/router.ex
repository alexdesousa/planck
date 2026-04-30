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

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", Planck.Web do
    pipe_through(:browser)

    live("/", SessionLive)
  end

  scope "/api" do
    pipe_through(:api)
    get("/openapi", OpenApiSpex.Plug.RenderSpec, [])
    get("/swaggerui", OpenApiSpex.Plug.SwaggerUI, path: "/api/openapi")
  end

  scope "/api", Planck.Web.API do
    pipe_through(:api)

    get("/sessions", SessionController, :index)
    post("/sessions", SessionController, :create)
    get("/sessions/:id", SessionController, :show)
    delete("/sessions/:id", SessionController, :close)
    post("/sessions/:id/prompt", SessionController, :prompt)
    post("/sessions/:id/abort", SessionController, :abort)
    get("/sessions/:id/events", EventController, :stream)

    get("/teams", TeamController, :index)
    get("/teams/:alias", TeamController, :show)

    get("/models", ModelController, :index)
  end
end
