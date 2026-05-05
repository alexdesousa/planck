import Config

# In a compiled release (Burrito binary), the Phoenix endpoint must be told
# to start the HTTP server. In dev/test this is set in dev.exs; here we
# ensure it is enabled at runtime for production builds.
if config_env() == :prod do
  config :planck_cli, Planck.Web.Endpoint, server: true
end
