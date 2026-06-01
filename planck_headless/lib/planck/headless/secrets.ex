defmodule Planck.Headless.Secrets do
  @moduledoc """
  Dispatch module for secret storage.

  Resolves the active `Planck.Agent.Secrets` implementation from config and
  delegates calls to it. Declare the implementation in `config.json`:

      { "secrets_hook": "Sidecar.Secrets.AgentVault" }

  When not set, `Planck.Headless.Secrets.EnvFile` is used — reads and writes
  `.planck/.env` (default behaviour, unchanged from earlier releases).

  See `Planck.Agent.Secrets` for the behaviour definition.
  """

  alias Planck.Agent.Secrets

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

  @doc "Fetch all secrets using the configured implementation."
  @spec fetch_all() :: Secrets.t()
  def fetch_all, do: resolve().fetch_all()

  @doc "List all secret keys using the configured implementation."
  @spec list() :: {:ok, [String.t()]} | {:error, term()}
  def list, do: resolve().list()

  @doc "Delete a secret using the configured implementation."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(key), do: resolve().delete(key)
end
