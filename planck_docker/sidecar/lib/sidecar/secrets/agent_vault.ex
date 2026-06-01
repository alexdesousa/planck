defmodule Sidecar.Secrets.AgentVault do
  @moduledoc """
  `Planck.Agent.Secrets` implementation backed by Infisical agent-vault.

  Stores and retrieves credentials, and manages service rules, via the
  agent-vault management HTTP API (port 14321).

  Authentication uses a scoped agent token with `proxy` role on the configured
  vault. The token is generated once by the setup container on first run and
  injected into the sidecar environment by `SidecarManager`.

  | Env var             | Default    | Description                        |
  |---------------------|------------|------------------------------------|
  | `AGENT_VAULT_URL`   | —          | Management API base URL (required) |
  | `AGENT_VAULT_TOKEN` | —          | Scoped agent token (required)      |
  | `AGENT_VAULT_VAULT` | `"planck"` | Vault name for Planck secrets      |
  """

  @behaviour Planck.Agent.Secrets

  require Logger

  # ---------------------------------------------------------------------------
  # Planck.Agent.Secrets callbacks — credentials
  # ---------------------------------------------------------------------------

  @impl Planck.Agent.Secrets
  @spec store(String.t(), String.t()) :: :ok | {:error, term()}
  def store(key, value) when is_binary(key) and is_binary(value) do
    case post("/v1/credentials", %{"vault" => vault(), "credentials" => %{key => value}}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Planck.Agent.Secrets
  @spec fetch(String.t()) :: {:ok, String.t()} | :not_found | {:error, term()}
  def fetch(key) when is_binary(key) do
    case get("/v1/credentials", vault: vault(), reveal: true, key: key) do
      {:ok, %{"credentials" => [%{"value" => val} | _]}} -> {:ok, val}
      {:ok, %{"credentials" => []}} -> :not_found
      {:ok, %{"credentials" => nil}} -> :not_found
      {:error, :not_found} -> :not_found
      {:error, reason} -> {:error, reason}
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
  @spec list() :: {:ok, [String.t()]} | {:error, term()}
  def list do
    case get("/v1/credentials", vault: vault()) do
      {:ok, %{"keys" => keys}} when is_list(keys) -> {:ok, keys}
      {:ok, _} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Planck.Agent.Secrets
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(key) when is_binary(key) do
    with {:ok, _} <- delete_req("/v1/credentials", %{"vault" => vault(), "keys" => [key]}) do
      delete_services_for(key)
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Planck.Agent.Secrets callbacks — service rules
  # ---------------------------------------------------------------------------

  @impl Planck.Agent.Secrets
  @spec store_service(String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def store_service(host, auth_type, credential_key, opts \\ []) do
    auth =
      case auth_type do
        "api-key" ->
          header = Keyword.fetch!(opts, :header)
          %{"type" => "api-key", "key" => credential_key, "header" => header}

        _ ->
          %{"type" => "bearer", "key" => credential_key}
      end

    name = String.replace(host, ".", "-")

    case post("/v1/vaults/#{vault()}/services", %{
           "services" => [%{"name" => name, "host" => host, "auth" => auth}]
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Planck.Agent.Secrets
  @spec delete_service(String.t()) :: :ok | {:error, term()}
  def delete_service(host) when is_binary(host) do
    case delete_req("/v1/vaults/#{vault()}/services/#{host}", %{}) do
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Planck.Agent.Secrets
  @spec list_services() :: {:ok, [Planck.Agent.Secrets.service()]} | {:error, term()}
  def list_services do
    case get("/v1/vaults/#{vault()}/services", []) do
      {:ok, %{"services" => services}} when is_list(services) ->
        {:ok, Enum.map(services, &parse_service/1)}

      {:ok, _} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Auto-migration
  # ---------------------------------------------------------------------------

  @doc """
  Migrates credentials and service rules from `.env` files to agent-vault if
  vault is reachable and `.env` files exist. Deletes the `.env` files after
  migration. Called at sidecar application start when `agent_vault_url` is
  configured.
  """
  @spec maybe_migrate() :: :ok
  def maybe_migrate do
    [".planck/.env", "~/.planck/.env"]
    |> Stream.map(&Path.expand/1)
    |> Enum.filter(&File.exists?/1)
    |> case do
      [] -> :ok
      paths -> migrate(paths)
    end
  end

  # ---------------------------------------------------------------------------
  # Private — HTTP
  # ---------------------------------------------------------------------------

  @spec delete_services_for(String.t()) :: :ok
  defp delete_services_for(key) do
    case list_services() do
      {:ok, services} ->
        services
        |> Enum.filter(&(&1.credential_key == key))
        |> Enum.each(&delete_service(&1.host))

      {:error, reason} ->
        Logger.warning(
          "[AgentVault] Could not list services to clean up after deleting #{key}: #{inspect(reason)}"
        )
    end

    :ok
  end

  @spec token() :: String.t() | nil
  defp token, do: Sidecar.Config.agent_vault_token!()

  @spec base_url() :: String.t() | nil
  defp base_url, do: Sidecar.Config.agent_vault_url!()

  @spec vault() :: String.t()
  defp vault, do: Sidecar.Config.agent_vault_vault!()

  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defp get(path, params) do
    case Req.get("#{base_url()}#{path}",
           params: params,
           headers: [{"authorization", "Bearer #{token()}"}],
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 401}} -> {:error, :unauthorized}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status, body: body}} -> {:error, {:unexpected, status, body}}
      {:error, reason} -> {:error, {:request_failed, reason}}
    end
  end

  @spec post(String.t(), map()) :: {:ok, map()} | {:error, term()}
  defp post(path, body) do
    case Req.post("#{base_url()}#{path}",
           json: body,
           headers: [{"authorization", "Bearer #{token()}"}],
           retry: false
         ) do
      {:ok, %{status: status, body: resp}} when status in [200, 201] -> {:ok, resp}
      {:ok, %{status: 401}} -> {:error, :unauthorized}
      {:ok, %{status: status, body: resp}} -> {:error, {:unexpected, status, resp}}
      {:error, reason} -> {:error, {:request_failed, reason}}
    end
  end

  @spec delete_req(String.t(), map()) :: {:ok, map()} | {:error, term()}
  defp delete_req(path, body) do
    case Req.delete("#{base_url()}#{path}",
           json: body,
           headers: [{"authorization", "Bearer #{token()}"}],
           retry: false
         ) do
      {:ok, %{status: 200, body: resp}} -> {:ok, resp}
      {:ok, %{status: 401}} -> {:error, :unauthorized}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status, body: resp}} -> {:error, {:unexpected, status, resp}}
      {:error, reason} -> {:error, {:request_failed, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — migration
  # ---------------------------------------------------------------------------

  @spec migrate([Path.t()]) :: :ok
  defp migrate(paths) do
    if is_nil(token()) or is_nil(base_url()) do
      Logger.warning("[AgentVault] Not configured — skipping migration.")
    else
      Enum.each(paths, &migrate_file/1)
    end
  end

  @spec migrate_file(Path.t()) :: :ok
  defp migrate_file(path) do
    {credentials, services} = parse_env_file(path)

    Enum.each(credentials, fn {key, value} ->
      case store(key, value) do
        :ok -> Logger.info("[AgentVault] Migrated credential #{key}.")
        {:error, r} -> Logger.warning("[AgentVault] Failed to migrate #{key}: #{inspect(r)}")
      end
    end)

    Enum.each(services, fn %{host: host, auth_type: type, credential_key: cred} = svc ->
      opts = if svc[:header], do: [header: svc.header], else: []

      case store_service(host, type, cred, opts) do
        :ok ->
          Logger.info("[AgentVault] Migrated service rule for #{host}.")

        {:error, r} ->
          Logger.warning("[AgentVault] Failed to migrate service #{host}: #{inspect(r)}")
      end
    end)

    File.rm(path)

    Logger.info(
      "[AgentVault] Migrated #{map_size(credentials)} credential(s) and " <>
        "#{length(services)} service rule(s) from #{path}. File deleted."
    )
  end

  @spec parse_env_file(Path.t()) ::
          {%{String.t() => String.t()}, [Planck.Agent.Secrets.service()]}
  defp parse_env_file(path) do
    case File.read(path) do
      {:ok, content} -> parse_env_content(content)
      _ -> {%{}, []}
    end
  end

  @spec parse_env_content(String.t()) ::
          {%{String.t() => String.t()}, [Planck.Agent.Secrets.service()]}
  defp parse_env_content(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.reduce({%{}, []}, fn line, {credentials, services} ->
      case line do
        "# planck-service: " <> _ = line ->
          {credentials, maybe_add_service_comment(services, line)}

        "#" <> _ ->
          {credentials, services}

        _ ->
          {maybe_add_credentials(credentials, line), services}
      end
    end)
    |> then(fn {credentials, services} ->
      {credentials, Enum.reverse(services)}
    end)
  end

  @spec maybe_add_service_comment([map()], String.t()) :: [map()]
  defp maybe_add_service_comment(services, line)

  defp maybe_add_service_comment(services, line)
       when is_list(services) and is_binary(line) do
    case parse_service_comment(line) do
      nil -> services
      service -> [service | services]
    end
  end

  @spec maybe_add_credentials(map(), String.t()) :: map()
  defp maybe_add_credentials(credentials, line)

  defp maybe_add_credentials(credentials, line)
       when is_map(credentials) and is_binary(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] -> Map.put(credentials, key, value)
      _ -> credentials
    end
  end

  # "# planck-service: api.n8n.com bearer N8N_API_KEY"
  # "# planck-service: api.custom.com api-key x-api-key CUSTOM_KEY"
  @spec parse_service_comment(String.t()) :: Planck.Agent.Secrets.service() | nil
  defp parse_service_comment(line) do
    rest = String.replace_prefix(line, "# planck-service: ", "")

    case String.split(rest, " ") do
      [host, "bearer", cred] ->
        %{host: host, auth_type: "bearer", credential_key: cred, header: nil}

      [host, "api-key", header, cred] ->
        %{host: host, auth_type: "api-key", credential_key: cred, header: header}

      _ ->
        nil
    end
  end

  @spec parse_service(map()) :: Planck.Agent.Secrets.service()
  defp parse_service(%{"host" => host, "auth" => auth}) do
    %{
      host: host,
      auth_type: auth["type"] || "bearer",
      credential_key: auth["key"] || "",
      header: auth["header"]
    }
  end

  @spec fetch_into(String.t(), Planck.Agent.Secrets.t()) :: Planck.Agent.Secrets.t()
  defp fetch_into(key, acc) do
    case fetch(key) do
      {:ok, value} -> Map.put(acc, key, value)
      _ -> acc
    end
  end
end
