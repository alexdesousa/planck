defmodule Planck.Agent.Secrets do
  @moduledoc """
  Behaviour for secret storage and service rule management in Planck.

  Declare the implementation module in `config.json`:

      { "secrets_hook": "Sidecar.Secrets.AgentVault" }

  When not set, `Planck.Headless.Secrets.EnvFile` is used — reads and writes
  `.planck/.env` and `~/.planck/.env`.

  Both `planck_headless` and the sidecar depend on `planck_agent`, so
  implementations in either package can reference this behaviour at compile time.

  ## Service rules

  Service rules tell the credential proxy which credentials to inject for
  outbound requests to a given host. The proxy injects unconditionally —
  the agent makes plain HTTP calls with no credential knowledge required.

  Rules are stored alongside credentials: `EnvFile` uses `# planck-service:`
  comment lines in `.env`; `AgentVault` uses the vault service rules API.
  """

  @typedoc "A map of secret key → value pairs."
  @type t :: %{optional(String.t()) => String.t()}

  @typedoc """
  A service rule that tells the credential proxy to inject a credential for
  all requests to the given host.

  - `auth_type` — `"bearer"` (Authorization header) or `"api-key"` (custom header)
  - `header` — the header name for `api-key` type (e.g. `"x-api-key"`); `nil` for bearer
  """
  @type service :: %{
          host: String.t(),
          auth_type: String.t(),
          credential_key: String.t(),
          header: String.t() | nil
        }

  @doc "Store a secret. Overwrites any existing value for the same key."
  @callback store(key :: String.t(), value :: String.t()) :: :ok | {:error, term()}

  @doc "Fetch a secret by key. Returns `:not_found` when absent."
  @callback fetch(key :: String.t()) :: {:ok, String.t()} | :not_found | {:error, term()}

  @doc "Fetch all secrets as a map."
  @callback fetch_all() :: t()

  @doc "List all stored secret keys."
  @callback list() :: {:ok, [String.t()]} | {:error, term()}

  @doc "Delete a secret by key. No-op if not found."
  @callback delete(key :: String.t()) :: :ok | {:error, term()}

  @doc """
  Upsert a service rule for the given host.

  `opts` may include `header: String.t()` when `auth_type` is `"api-key"`.
  """
  @callback store_service(
              host :: String.t(),
              auth_type :: String.t(),
              credential_key :: String.t(),
              opts :: keyword()
            ) :: :ok | {:error, term()}

  @doc "Delete the service rule for the given host. No-op if not found."
  @callback delete_service(host :: String.t()) :: :ok | {:error, term()}

  @doc "List all configured service rules."
  @callback list_services() :: {:ok, [service()]} | {:error, term()}
end
