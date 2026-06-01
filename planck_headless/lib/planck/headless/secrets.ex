defmodule Planck.Headless.Secrets do
  @moduledoc """
  Dispatch module for secret storage.

  Resolves the active `Planck.Agent.Secrets` implementation from config and
  delegates calls to it. Declare the implementation in `config.json`:

      { "secrets_hook": "Sidecar.Secrets.AgentVault" }

  When not set, `Planck.Headless.Secrets.EnvFile` is used — reads and writes
  `.planck/.env` (default behaviour, unchanged from earlier releases).

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
  alias Planck.Headless.{Config, SidecarManager}

  @rpc_timeout_ms 30_000

  @doc "Return the configured secrets module, defaulting to `EnvFile`."
  @spec resolve() :: module()
  def resolve do
    case Config.secrets_hook!() do
      nil -> __MODULE__.EnvFile
      mod when is_binary(mod) -> String.to_atom("Elixir.#{mod}")
    end
  end

  @doc "Store a secret using the configured implementation."
  @spec store(String.t(), String.t()) :: :ok | {:error, term()}
  def store(key, value), do: dispatch(:store, [key, value], {:error, :sidecar_not_connected})

  @doc "Fetch a secret using the configured implementation."
  @spec fetch(String.t()) :: {:ok, String.t()} | :not_found | {:error, term()}
  def fetch(key), do: dispatch(:fetch, [key], {:error, :sidecar_not_connected})

  @doc "Fetch all secrets using the configured implementation."
  @spec fetch_all() :: Secrets.t()
  def fetch_all, do: dispatch(:fetch_all, [], %{})

  @doc "List all secret keys using the configured implementation."
  @spec list() :: {:ok, [String.t()]} | {:error, term()}
  def list, do: dispatch(:list, [], {:error, :sidecar_not_connected})

  @doc "Delete a secret using the configured implementation."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(key), do: dispatch(:delete, [key], {:error, :sidecar_not_connected})

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
