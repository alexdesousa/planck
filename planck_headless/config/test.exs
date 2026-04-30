import Config

# Prevent the JsonBinding from reading real ~/.planck/config.json in tests.
config :planck_headless, :skip_json_config, true

# Skip network model discovery during tests — local servers (ollama, llama_cpp)
# are not running and would add several seconds of timeouts per reload.
config :planck_headless, :skip_model_detection, true
