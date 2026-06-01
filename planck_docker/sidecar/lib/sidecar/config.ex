defmodule Sidecar.Config do
  @moduledoc """
  Runtime configuration for the planck_docker bundled sidecar.

  Values are resolved by Skogsra from (highest priority first):

  1. Environment variables
  2. Application config (`config :sidecar, ...`)
  3. Hardcoded defaults

  | Key | Env var | Default |
  |---|---|---|
  | `workspace_dir` | `WORKSPACE_DIR` | `/workspace` |
  | `searxng_url` | `SEARXNG_URL` | `http://searxng:8080` |
  | `typesense_url` | `TYPESENSE_URL` | `http://typesense:8108` |
  | `typesense_api_key` | `TYPESENSE_API_KEY` | `planck-internal-key` |
  | `typesense_collection` | `TYPESENSE_COLLECTION` | `workspace` |
  | `sessions_collection` | `TYPESENSE_SESSIONS_COLLECTION` | `long_term_memory` |
  | `memory_collection` | `TYPESENSE_MEMORY_COLLECTION` | `short_term_memory` |
  """
  use Skogsra

  @envdoc "Absolute path to the mounted workspace directory."
  app_env :workspace_dir, :sidecar, :workspace_dir,
    os_env: "WORKSPACE_DIR",
    default: "/workspace"

  @envdoc "Base URL of the Typesense instance (internal Docker service)."
  app_env :typesense_url, :sidecar, :typesense_url,
    os_env: "TYPESENSE_URL",
    default: "http://typesense:8108"

  @envdoc "API key for the Typesense instance."
  app_env :typesense_api_key, :sidecar, :typesense_api_key,
    os_env: "TYPESENSE_API_KEY",
    default: "planck-internal-key"

  @envdoc "Base URL of the Searxng instance (internal Docker service)."
  app_env :searxng_url, :sidecar, :searxng_url,
    os_env: "SEARXNG_URL",
    default: "http://searxng:8080"

  @envdoc "Name of the Typesense collection used for workspace file indexing."
  app_env :typesense_collection, :sidecar, :typesense_collection,
    os_env: "TYPESENSE_COLLECTION",
    default: "workspace"

  @envdoc "Name of the Typesense collection used for long-term session turn indexing (session_search)."
  app_env :sessions_collection, :sidecar, :sessions_collection,
    os_env: "TYPESENSE_SESSIONS_COLLECTION",
    default: "long_term_memory"

  @envdoc "Name of the Typesense collection used for short-term agent memory (prompt injection)."
  app_env :memory_collection, :sidecar, :memory_collection,
    os_env: "TYPESENSE_MEMORY_COLLECTION",
    default: "short_term_memory"

  @envdoc "Base URL of the Apache Tika Server instance (internal Docker service)."
  app_env :tika_url, :sidecar, :tika_url,
    os_env: "TIKA_URL",
    default: "http://tika:9998"

  app_env :agent_vault_url, :sidecar, :agent_vault_url,
    os_env: "AGENT_VAULT_URL",
    default: nil

  app_env :agent_vault_email, :sidecar, :agent_vault_email,
    os_env: "AGENT_VAULT_EMAIL",
    default: nil

  app_env :agent_vault_password, :sidecar, :agent_vault_password,
    os_env: "AGENT_VAULT_PASSWORD",
    default: nil

  app_env :agent_vault_vault, :sidecar, :agent_vault_vault,
    os_env: "AGENT_VAULT_VAULT",
    default: "planck"
end
