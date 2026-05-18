import Config

# In a compiled release (Burrito binary), the Phoenix endpoint must be told
# to start the HTTP server. In dev/test this is set in dev.exs; here we
# ensure it is enabled at runtime for production builds.
if config_env() == :prod do
  config :planck_cli, Planck.Web.Endpoint, server: true

  # Local CPU inference can take a long time to process large prompts before
  # emitting the first token. Use a 1-hour timeout — effectively unlimited for
  # interactive use. (Cannot use :infinity — req_llm passes it to send_after/3.)
  config :req_llm, receive_timeout: :timer.hours(1)
end
