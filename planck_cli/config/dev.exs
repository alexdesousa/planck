import Config

config :planck_cli, Planck.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  server: true,
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:planck_cli, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:planck_cli, ~w(--watch)]}
  ],
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
      ~r"lib/planck/web/(live|components|layouts)/.*\.(ex|heex)$"E,
      ~r"lib/planck/web\.ex$"E,
      ~r"lib/planck/web/router\.ex$"E
    ]
  ]

config :planck_headless, :skip_json_config, true

config :logger, :default_formatter, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true
