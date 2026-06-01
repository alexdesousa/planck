defmodule Planck.Agent.Secrets do
  @moduledoc """
  Behaviour for secret storage in Planck.

  Declare the implementation module in `config.json`:

      { "secrets_hook": "Sidecar.Secrets.AgentVault" }

  When not set, `Planck.Headless.Secrets.EnvFile` is used — reads and writes
  `.planck/.env` and `~/.planck/.env`.

  Both `planck_headless` and the sidecar depend on `planck_agent`, so
  implementations in either package can reference this behaviour at compile time.
  """

  @typedoc "A map of secret key → value pairs."
  @type t :: %{optional(String.t()) => String.t()}

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
end
