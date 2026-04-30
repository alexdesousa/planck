defmodule Planck.Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :planck_cli

  @session_options [
    store: :cookie,
    key: "_planck_key",
    signing_salt: "yOHXNHTP",
    same_site: "Lax"
  ]

  if Application.compile_env(:planck_cli, :dev_routes, false) do
    plug Tidewave, allow_remote_access: true
  end

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :planck_cli,
    gzip: not code_reloading?,
    only: Planck.Web.static_paths(),
    raise_on_missing_only: code_reloading?

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug OpenApiSpex.Plug.PutApiSpec, module: Planck.Web.API.Spec
  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug Planck.Web.Router
end
