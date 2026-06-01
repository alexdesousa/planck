defmodule Planck.Headless.Secrets do
  @moduledoc """
  Dispatch module for secret storage.

  Resolves the active `Planck.Agent.Secrets` implementation from config and
  delegates calls to it. Declare the implementation in `config.json`:

      { "secrets_hook": "Sidecar.Secrets.AgentVault" }

  When not set, `Planck.Headless.Secrets.EnvFile` is used — reads and writes
  `.planck/.env` (default behaviour, unchanged from earlier releases).

  ## Process environment sync

  Whenever a secret is stored or deleted, the change is mirrored into the
  OS process environment via `System.put_env/2` or `System.delete_env/1` and
  `ResourceStore.reload/0` is called so Skogsra picks up the new value without
  a restart.

  `preload_to_env/0` loads all stored secrets into the process env at once —
  call it at application boot and after `.env` file changes (EnvFile backend only).

  ## Remote dispatch

  When the configured module lives on the sidecar node (e.g.
  `Sidecar.Secrets.AgentVault`), calls are dispatched via `:rpc.call/5` to the
  connected sidecar. If the sidecar is not connected, calls return
  `{:error, :sidecar_not_connected}` (or `%{}` for `fetch_all/0`).

  `Planck.Headless.Secrets.EnvFile` is always called in-process.

  See `Planck.Agent.Secrets` for the behaviour definition.
  """

  require Logger

  alias Planck.Agent.Secrets
  alias Planck.Headless.{Config, ResourceStore, SidecarManager}

  @rpc_timeout_ms 30_000

  @doc "Return the configured secrets module, defaulting to `EnvFile`."
  @spec resolve() :: module()
  def resolve do
    case Config.secrets_hook!() do
      nil -> __MODULE__.EnvFile
      mod when is_binary(mod) -> String.to_atom("Elixir.#{mod}")
    end
  end

  @doc """
  Load all stored secrets into the OS process environment via `System.put_env/2`.

  Call at application boot and whenever the secrets store changes on disk
  (EnvFile backend). Does NOT call `ResourceStore.reload/0` — callers are
  responsible for triggering a Skogsra refresh if needed.
  """
  @spec preload_to_env() :: :ok
  def preload_to_env do
    fetch_all()
    |> Enum.each(fn {key, value} -> System.put_env(key, value) end)
  end

  @doc "Store a secret and sync to the process environment."
  @spec store(String.t(), String.t()) :: :ok | {:error, term()}
  def store(key, value) do
    with :ok <- dispatch(:store, [key, value], {:error, :sidecar_not_connected}) do
      System.put_env(key, value)
      ResourceStore.reload()
      :ok
    end
  end

  @doc "Fetch a secret using the configured implementation."
  @spec fetch(String.t()) :: {:ok, String.t()} | :not_found | {:error, term()}
  def fetch(key), do: dispatch(:fetch, [key], {:error, :sidecar_not_connected})

  @doc "Fetch all secrets as a map using the configured implementation."
  @spec fetch_all() :: Secrets.t()
  def fetch_all, do: dispatch(:fetch_all, [], %{})

  @doc "List all secret keys using the configured implementation."
  @spec list() :: {:ok, [String.t()]} | {:error, term()}
  def list, do: dispatch(:list, [], {:error, :sidecar_not_connected})

  @doc "Delete a secret and remove it from the process environment."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(key) do
    with :ok <- dispatch(:delete, [key], {:error, :sidecar_not_connected}) do
      System.delete_env(key)
      ResourceStore.reload()
      :ok
    end
  end

  @doc "Upsert a service rule for the given host."
  @spec store_service(String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def store_service(host, auth_type, credential_key, opts \\ []) do
    dispatch(
      :store_service,
      [host, auth_type, credential_key, opts],
      {:error, :sidecar_not_connected}
    )
  end

  @doc "Delete the service rule for the given host."
  @spec delete_service(String.t()) :: :ok | {:error, term()}
  def delete_service(host) do
    dispatch(:delete_service, [host], {:error, :sidecar_not_connected})
  end

  @doc "List all configured service rules."
  @spec list_services() :: {:ok, [Planck.Agent.Secrets.service()]} | {:error, term()}
  def list_services do
    dispatch(:list_services, [], {:error, :sidecar_not_connected})
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec dispatch(atom(), [term()], term()) :: term()
  defp dispatch(function, args, fallback) do
    mod = resolve()

    cond do
      mod == __MODULE__.EnvFile ->
        apply(mod, function, args)

      node = SidecarManager.node() ->
        :rpc.call(node, :code, :ensure_loaded, [mod], @rpc_timeout_ms)

        case :rpc.call(node, mod, function, args, @rpc_timeout_ms) do
          {:badrpc, reason} ->
            Logger.warning(
              "[Planck.Headless.Secrets] RPC failed (#{mod}.#{function}): #{inspect(reason)}"
            )

            fallback

          result ->
            result
        end

      true ->
        Logger.warning(
          "[Planck.Headless.Secrets] #{mod}.#{function} called but sidecar is not connected"
        )

        fallback
    end
  end
end
