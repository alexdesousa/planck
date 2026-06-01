defmodule Sidecar.Secrets.AgentVault do
  @moduledoc """
  `Planck.Headless.Secrets` implementation backed by Infisical agent-vault.

  Stores and retrieves API keys via the agent-vault management HTTP API
  (port 14321). Configured via:

  | Env var                | Default   | Description                        |
  |------------------------|-----------|------------------------------------|
  | `AGENT_VAULT_URL`      | —         | Management API base URL (required) |
  | `AGENT_VAULT_EMAIL`    | —         | Admin email (required)             |
  | `AGENT_VAULT_PASSWORD` | —         | Admin password (required)          |
  | `AGENT_VAULT_VAULT`    | `"planck"`| Vault name for Planck secrets      |

  The session token obtained from `/v1/auth/login` is cached in
  `:persistent_term` and refreshed automatically on `401` responses.
  """

  @behaviour Planck.Agent.Secrets

  require Logger

  @token_key {__MODULE__, :token}

  # ---------------------------------------------------------------------------
  # Planck.Agent.Secrets callbacks
  # Each also accepts an optional keyword list for internal retry control.
  # ---------------------------------------------------------------------------

  @impl Planck.Agent.Secrets
  @spec store(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def store(key, value, options \\ [])

  def store(key, value, options) when is_binary(key) and is_binary(value) do
    with {:ok, token} <- ensure_token() do
      do_store(token, key, value, options)
    end
  end

  @impl Planck.Agent.Secrets
  @spec fetch(String.t(), keyword()) :: {:ok, String.t()} | :not_found | {:error, term()}
  def fetch(key, options \\ [])

  def fetch(key, options) when is_binary(key) do
    with {:ok, token} <- ensure_token() do
      do_fetch(token, key, options)
    end
  end

  @impl Planck.Agent.Secrets
  @spec fetch_all() :: Planck.Agent.Secrets.t()
  def fetch_all do
    case list() do
      {:ok, keys} -> Enum.reduce(keys, %{}, &fetch_into/2)
      _ -> %{}
    end
  end

  @impl Planck.Agent.Secrets
  @spec list(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def list(options \\ []) do
    with {:ok, token} <- ensure_token() do
      do_list(token, options)
    end
  end

  @impl Planck.Agent.Secrets
  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(key, options \\ []) do
    with {:ok, token} <- ensure_token() do
      do_delete(token, key, options)
    end
  end

  # ---------------------------------------------------------------------------
  # Auto-migration
  # ---------------------------------------------------------------------------

  @doc """
  Migrate API keys from `.env` files to agent-vault if vault is reachable
  and `.env` files exist. Deletes the `.env` files after migration.
  Called at sidecar application start when `agent_vault_url` is configured.
  """
  @spec maybe_migrate() :: :ok
  def maybe_migrate do
    [".planck/.env", "~/.planck/.env"]
    |> Enum.filter(fn path ->
      path
      |> Path.expand()
      |> File.exists?()
    end)
    |> case do
      [] -> :ok
      [_ | _] = existing -> migrate(existing)
    end
  end

  # ---------------------------------------------------------------------------
  # Private — HTTP helpers
  # ---------------------------------------------------------------------------

  @spec ensure_token() :: {:ok, String.t()} | {:error, term()}
  defp ensure_token do
    case :persistent_term.get(@token_key, nil) do
      nil -> login()
      token -> {:ok, token}
    end
  end

  @spec login() :: {:ok, String.t()} | {:error, term()}
  defp login do
    url = Sidecar.Config.agent_vault_url!()
    email = Sidecar.Config.agent_vault_email!()
    password = Sidecar.Config.agent_vault_password!()

    params = [
      retry: false,
      json: %{
        "email" => email,
        "password" => password
      }
    ]

    with false <- is_nil(url) or is_nil(email) or is_nil(password),
         {:ok, %{status: 200, body: %{"token" => token}}} <-
           Req.post("#{url}/v1/auth/login", params) do
      :persistent_term.put(@token_key, token)
      {:ok, token}
    else
      true ->
        {:error, :vault_not_configured}

      {:ok, %{status: status, body: body}} ->
        {:error, {:login_failed, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @spec invalidate_token() :: :ok
  defp invalidate_token do
    :persistent_term.erase(@token_key)
    :ok
  end

  @spec get(String.t(), keyword(), String.t()) :: {:ok, map()} | {:error, term()}
  defp get(path, params, token) do
    case Req.get("#{base_url()}#{path}",
           params: params,
           headers: [{"authorization", "Bearer #{token}"}],
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 401}} -> {:error, :unauthorized}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status, body: body}} -> {:error, {:unexpected, status, body}}
      {:error, reason} -> {:error, {:request_failed, reason}}
    end
  end

  @spec post(String.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  defp post(path, body, token) do
    case Req.post("#{base_url()}#{path}",
           json: body,
           headers: [{"authorization", "Bearer #{token}"}],
           retry: false
         ) do
      {:ok, %{status: 200, body: resp}} -> {:ok, resp}
      {:ok, %{status: 401}} -> {:error, :unauthorized}
      {:ok, %{status: status, body: resp}} -> {:error, {:unexpected, status, resp}}
      {:error, reason} -> {:error, {:request_failed, reason}}
    end
  end

  @spec delete_req(String.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  defp delete_req(path, body, token) do
    case Req.delete("#{base_url()}#{path}",
           json: body,
           headers: [{"authorization", "Bearer #{token}"}],
           retry: false
         ) do
      {:ok, %{status: 200, body: resp}} -> {:ok, resp}
      {:ok, %{status: 401}} -> {:error, :unauthorized}
      {:ok, %{status: status, body: resp}} -> {:error, {:unexpected, status, resp}}
      {:error, reason} -> {:error, {:request_failed, reason}}
    end
  end

  @spec base_url() :: String.t()
  defp base_url, do: Sidecar.Config.agent_vault_url!()

  @spec vault() :: String.t()
  defp vault, do: Sidecar.Config.agent_vault_vault!()

  # ---------------------------------------------------------------------------
  # Private — helpers (re-login on 401)
  # ---------------------------------------------------------------------------

  @spec do_store(String.t(), String.t(), String.t(), keyword()) ::
          :ok
          | {:error, term()}
  defp do_store(token, key, value, options)

  defp do_store(token, key, value, options)
       when is_binary(token) and is_binary(key) and is_binary(value) do
    body = %{"vault" => vault(), "credentials" => %{key => value}}
    retry = Keyword.get(options, :retry, true)

    case post("/v1/credentials", body, token) do
      {:ok, _} ->
        :ok

      {:error, :unauthorized} when retry ->
        invalidate_token()
        store(key, value, retry: false)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec do_fetch(String.t(), String.t(), keyword()) ::
          {:ok, String.t()}
          | {:error, :not_found}
          | {:error, term()}
  defp do_fetch(token, key, options)

  defp do_fetch(token, key, options)
       when is_binary(token) and is_binary(key) do
    params = [vault: vault(), reveal: true, key: key]
    retry = Keyword.get(options, :retry, true)

    case get("/v1/credentials", params, token) do
      {:ok, %{"credentials" => [%{"value" => val} | _]}} ->
        {:ok, val}

      {:ok, %{"credentials" => []}} ->
        {:error, :not_found}

      {:ok, %{"credentials" => nil}} ->
        {:error, :not_found}

      {:error, :unauthorized} when retry ->
        invalidate_token()
        fetch(key, retry: false)

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec do_list(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  defp do_list(token, options)

  defp do_list(token, options) when is_binary(token) do
    retry = Keyword.get(options, :retry, true)

    case get("/v1/credentials", [vault: vault()], token) do
      {:ok, %{"keys" => keys}} when is_list(keys) ->
        {:ok, keys}

      {:ok, _} ->
        {:ok, []}

      {:error, :unauthorized} when retry ->
        invalidate_token()
        list(retry: false)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec do_delete(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  defp do_delete(token, key, options)

  defp do_delete(token, key, options)
       when is_binary(token) and is_binary(key) do
    body = %{"vault" => vault(), "keys" => [key]}
    retry = Keyword.get(options, :retry, true)

    case delete_req("/v1/credentials", body, token) do
      {:ok, _} ->
        :ok

      {:error, :unauthorized} when retry ->
        invalidate_token()
        delete(key, retry: false)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — migration
  # ---------------------------------------------------------------------------

  @spec migrate([Path.t()]) :: :ok
  defp migrate(existing) do
    case ensure_token() do
      {:ok, _} ->
        Enum.each(existing, &migrate_file/1)

      {:error, reason} ->
        reason =
          "[Sidecar.Secrets.AgentVault] Cannot connect to agent-vault for migration: " <>
            "#{inspect(reason)}. " <>
            "API keys remain in .env files."

        Logger.warning(reason)
    end
  end

  @spec migrate_file(Path.t()) :: :ok
  defp migrate_file(path) do
    expanded = Path.expand(path)
    pairs = parse_env_file(expanded)

    Enum.each(pairs, fn {key, value} ->
      case store(key, value) do
        :ok ->
          Logger.info("[Sidecar.Secrets.AgentVault] Migrated #{key} to vault.")

        {:error, reason} ->
          Logger.warning(
            "[Sidecar.Secrets.AgentVault] Failed to migrate #{key}: #{inspect(reason)}"
          )
      end
    end)

    File.rm(expanded)

    Logger.warning(
      "[Sidecar.Secrets.AgentVault] Migrated #{map_size(pairs)} key(s) from #{path} " <>
        "to agent-vault. The .env file has been deleted."
    )
  end

  @spec parse_env_file(Path.t()) :: %{String.t() => String.t()}
  defp parse_env_file(path) do
    case File.read(path) do
      {:ok, content} -> parse_env_content(content)
      _ -> %{}
    end
  end

  @spec parse_env_content(String.t()) :: Planck.Agent.Secrets.t()
  defp parse_env_content(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, "=", parts: 2) do
        [k, v] -> [{k, v}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  @spec fetch_into(String.t(), Planck.Agent.Secrets.t()) :: Planck.Agent.Secrets.t()
  defp fetch_into(key, acc) do
    case fetch(key) do
      {:ok, value} -> Map.put(acc, key, value)
      _ -> acc
    end
  end
end
