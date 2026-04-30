import Config

config :planck_cli, Planck.Web.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: Planck.Web.ErrorHTML],
    layout: false
  ],
  pubsub_server: Planck.Agent.PubSub,
  live_view: [signing_salt: "DUVIkbVpBWbQ2CPSXFdqF2dw3MoJOJ0H"]

config :esbuild,
  version: "0.25.4",
  planck_cli: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  version: "4.1.12",
  planck_cli: [
    args: ~w(--input=assets/css/app.css --output=priv/static/assets/css/app.css),
    cd: Path.expand("..", __DIR__)
  ]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
