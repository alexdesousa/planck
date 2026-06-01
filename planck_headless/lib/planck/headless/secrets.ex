defmodule Planck.Headless.Secrets do
  @moduledoc """
  Behaviour for secret storage in Planck.

  Declare the implementation module in `config.json`:

      { "secrets_hook": "Sidecar.Secrets.AgentVault" }

  When not set, `Planck.Headless.Secrets.EnvFile` is used — reads and writes
  `.planck/.env` (current default behaviour, unchanged).

  Use `resolve/0` to get the active module, or call the convenience functions
  which delegate to it automatically.
  """

  @doc "Store a secret by key."
  @callback store(key :: String.t(), value :: String.t()) :: :ok | {:error, term()}

  @doc "Fetch a secret by key. Returns `:not_found` when absent."
  @callback fetch(key :: String.t()) :: {:ok, String.t()} | :not_found | {:error, term()}

  @doc "List all stored secret keys."
  @callback list() :: {:ok, [String.t()]} | {:error, term()}

  @doc "Delete a secret by key. No-op if not found."
  @callback delete(key :: String.t()) :: :ok | {:error, term()}

  @doc "Return the configured secrets module, defaulting to `EnvFile`."
  @spec resolve() :: module()
  def resolve do
    case Planck.Headless.Config.secrets_hook!() do
      nil -> __MODULE__.EnvFile
      mod when is_binary(mod) -> String.to_existing_atom("Elixir.#{mod}")
    end
  end

  @doc "Store a secret using the configured implementation."
  @spec store(String.t(), String.t()) :: :ok | {:error, term()}
  def store(key, value), do: resolve().store(key, value)

  @doc "Fetch a secret using the configured implementation."
  @spec fetch(String.t()) :: {:ok, String.t()} | :not_found | {:error, term()}
  def fetch(key), do: resolve().fetch(key)

  @doc "List all secret keys using the configured implementation."
  @spec list() :: {:ok, [String.t()]} | {:error, term()}
  def list, do: resolve().list()

  @doc "Delete a secret using the configured implementation."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(key), do: resolve().delete(key)
end
