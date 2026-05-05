import Config

# Prevent the JsonBinding from reading real ~/.planck/config.json in tests.
config :planck_headless, :skip_json_config, true

# Prevent the EnvBinding from reading real ~/.planck/.env in tests.
config :planck_headless, :skip_env_config, true

# Use the planck_agent mock AI client so session lifecycle tests do not hit
# real LLM providers.
config :planck_agent, :ai_client, Planck.Agent.MockAI
