import Config

config :planck_headless, :skip_json_config, true
config :planck_agent, :ai_client, Planck.Agent.MockAI

config :planck_cli, Planck.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  server: false
