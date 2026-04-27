defmodule Planck.CLI.Config do
  @moduledoc """
  Runtime configuration for `planck_cli`.

  Values are resolved by Skogsra from (highest priority first):

  1. Environment variables
  2. Application config (`config :planck_cli, ...`)
  3. Per-environment defaults

  Call `preload/0` before starting any supervised children so Phoenix and
  other dependencies read the resolved values via `Application.get_env/2`.
  """

  use Skogsra

  @envdoc "Phoenix endpoint secret key base."
  app_env :secret_key_base, :planck_cli, ["Elixir.Planck.Web.Endpoint", :secret_key_base],
    type: :binary,
    os_env: "SECRET_KEY_BASE",
    env_overrides: [
      dev: [default: "ktGG3zm3ZlYJnp6QqlvdH69bMgTT6H+gkCecYkXgYYp3a3YqaVpPGqH2JdjbbF0o"],
      test: [default: "vbREe4KPexSPleDG9tJVpfWcrTOPlKXXBDGS3+lU+a8H6t6NX5bJhC3waVBH8AH0"],
      prod: [required: true]
    ]

  @envdoc "HTTP port for the web UI."
  app_env :port, :planck_cli, ["Elixir.Planck.Web.Endpoint", :http, :port],
    type: :integer,
    os_env: "PORT",
    env_overrides: [
      dev: [default: 4000],
      test: [default: 4002],
      prod: [default: 4000]
    ]
end
