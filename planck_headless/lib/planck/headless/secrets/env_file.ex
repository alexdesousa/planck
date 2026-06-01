defmodule Planck.Headless.Secrets.EnvFile do
  @moduledoc """
  Default `Planck.Agent.Secrets` implementation that reads and writes
  API keys and service rules to `.planck/.env` and `~/.planck/.env`.

  Credentials are stored as `KEY=value` lines. Service rules are stored as
  `# planck-service:` comment lines, which standard `.env` parsers (including
  Skogsra's `EnvBinding`) ignore:

      N8N_API_KEY=secret
      # planck-service: api.n8n.com bearer N8N_API_KEY
      # planck-service: api.custom.com api-key x-api-key CUSTOM_KEY

  Both credential writes and service rule writes preserve the other section,
  so the two types of data coexist safely in the same file.
  """

  @behaviour Planck.Agent.Secrets

  @local_path ".planck/.env"
  @global_path "~/.planck/.env"

  # ---------------------------------------------------------------------------
  # Credentials
  # ---------------------------------------------------------------------------

  @impl true
  @spec store(String.t(), String.t()) :: :ok | {:error, term()}
  def store(key, value) do
    {creds, svcs} = read_file(@local_path)
    write_file(@local_path, Map.put(creds, key, value), svcs)
  end

  @impl true
  @spec fetch(String.t()) :: {:ok, String.t()} | :not_found | {:error, term()}
  def fetch(key) do
    case Map.get(merge_credentials(), key) do
      nil -> :not_found
      value -> {:ok, value}
    end
  end

  @impl true
  @spec fetch_all() :: Planck.Agent.Secrets.t()
  def fetch_all, do: merge_credentials()

  @impl true
  @spec list() :: {:ok, [String.t()]} | {:error, term()}
  def list, do: {:ok, Map.keys(merge_credentials())}

  @impl true
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(key) do
    {local_creds, local_svcs} = read_file(@local_path)

    if Map.has_key?(local_creds, key) do
      write_file(@local_path, Map.delete(local_creds, key), drop_services_for(local_svcs, key))
    else
      write_file(@local_path, local_creds, drop_services_for(local_svcs, key))
      {global_creds, global_svcs} = read_file(@global_path)
      write_file(@global_path, Map.delete(global_creds, key), drop_services_for(global_svcs, key))
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Service rules
  # ---------------------------------------------------------------------------

  @impl true
  @spec store_service(String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def store_service(host, auth_type, credential_key, opts \\ []) do
    {creds, svcs} = read_file(@local_path)
    svc = build_service(host, auth_type, credential_key, opts)
    updated = Enum.reject(svcs, &(&1.host == host)) ++ [svc]
    write_file(@local_path, creds, updated)
  end

  @impl true
  @spec delete_service(String.t()) :: :ok | {:error, term()}
  def delete_service(host) do
    for path <- [@local_path, @global_path] do
      {creds, svcs} = read_file(path)
      write_file(path, creds, Enum.reject(svcs, &(&1.host == host)))
    end

    :ok
  end

  @impl true
  @spec list_services() :: {:ok, [Planck.Agent.Secrets.service()]} | {:error, term()}
  def list_services do
    {_, global_svcs} = read_file(@global_path)
    {_, local_svcs} = read_file(@local_path)

    {:ok, Enum.uniq_by(global_svcs ++ local_svcs, & &1.host)}
  end

  # ---------------------------------------------------------------------------
  # Internal — used by headless.ex for write-on-configure
  # ---------------------------------------------------------------------------

  @doc """
  Write a key=value pair to the given `.env` file path.

  Creates the file and its parent directories if they don't exist.
  Updates the line in-place if the key already exists. Preserves any
  existing `# planck-service:` comment lines.
  """
  @spec write_to(Path.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def write_to(path, key, value) do
    {creds, svcs} = read_file(path)
    write_file(path, Map.put(creds, key, value), svcs)
  end

  # ---------------------------------------------------------------------------
  # Private — file I/O
  # ---------------------------------------------------------------------------

  @spec read_file(Path.t()) :: {Planck.Agent.Secrets.t(), [Planck.Agent.Secrets.service()]}
  defp read_file(path) do
    case File.read(Path.expand(path)) do
      {:ok, content} -> parse_content(content)
      _ -> {%{}, []}
    end
  end

  @spec write_file(Path.t(), Planck.Agent.Secrets.t(), [Planck.Agent.Secrets.service()]) ::
          :ok | {:error, term()}
  defp write_file(path, credentials, services) do
    with :ok <- File.mkdir_p(path |> Path.expand() |> Path.dirname()) do
      File.write(Path.expand(path), serialize(credentials, services))
    end
  end

  @spec merge_credentials() :: Planck.Agent.Secrets.t()
  defp merge_credentials do
    {global_creds, _} = read_file(@global_path)
    {local_creds, _} = read_file(@local_path)
    Map.merge(global_creds, local_creds)
  end

  @spec drop_services_for([Planck.Agent.Secrets.service()], String.t()) ::
          [Planck.Agent.Secrets.service()]
  defp drop_services_for(services, credential_key) do
    Enum.reject(services, &(&1.credential_key == credential_key))
  end

  # ---------------------------------------------------------------------------
  # Private — parsing
  # ---------------------------------------------------------------------------

  @spec parse_content(String.t()) ::
          {Planck.Agent.Secrets.t(), [Planck.Agent.Secrets.service()]}
  defp parse_content(content) do
    {creds, svcs} =
      content
      |> String.split("\n", trim: true)
      |> Enum.reduce({%{}, []}, &parse_line/2)

    {creds, Enum.reverse(svcs)}
  end

  @spec parse_line(String.t(), {Planck.Agent.Secrets.t(), [Planck.Agent.Secrets.service()]}) ::
          {Planck.Agent.Secrets.t(), [Planck.Agent.Secrets.service()]}
  defp parse_line("# planck-service: " <> rest, {creds, svcs}) do
    case parse_service_fields(rest) do
      nil -> {creds, svcs}
      svc -> {creds, [svc | svcs]}
    end
  end

  defp parse_line("#" <> _, acc), do: acc

  defp parse_line(line, {creds, svcs}) do
    case String.split(line, "=", parts: 2) do
      [k, v] -> {Map.put(creds, k, v), svcs}
      _ -> {creds, svcs}
    end
  end

  # "api.n8n.com bearer N8N_API_KEY"
  # "api.custom.com api-key x-api-key CUSTOM_KEY"
  @spec parse_service_fields(String.t()) :: Planck.Agent.Secrets.service() | nil
  defp parse_service_fields(rest) do
    case String.split(rest, " ") do
      [host, "bearer", cred] ->
        %{host: host, auth_type: "bearer", credential_key: cred, header: nil}

      [host, "api-key", header, cred] ->
        %{host: host, auth_type: "api-key", credential_key: cred, header: header}

      _ ->
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # Private — serialization
  # ---------------------------------------------------------------------------

  @spec serialize(Planck.Agent.Secrets.t(), [Planck.Agent.Secrets.service()]) :: String.t()
  defp serialize(credentials, services) do
    cred_block = Enum.map_join(credentials, "\n", fn {k, v} -> "#{k}=#{v}" end)
    svc_block = Enum.map_join(services, "\n", &serialize_service/1)

    case {cred_block, svc_block} do
      {"", ""} -> ""
      {creds, ""} -> creds <> "\n"
      {"", svcs} -> svcs <> "\n"
      {creds, svcs} -> creds <> "\n" <> svcs <> "\n"
    end
  end

  @spec serialize_service(Planck.Agent.Secrets.service()) :: String.t()
  defp serialize_service(%{host: host, auth_type: "api-key", credential_key: cred, header: hdr}),
    do: "# planck-service: #{host} api-key #{hdr} #{cred}"

  defp serialize_service(%{host: host, auth_type: type, credential_key: cred}),
    do: "# planck-service: #{host} #{type} #{cred}"

  @spec build_service(String.t(), String.t(), String.t(), keyword()) ::
          Planck.Agent.Secrets.service()
  defp build_service(host, "api-key", cred, opts),
    do: %{
      host: host,
      auth_type: "api-key",
      credential_key: cred,
      header: Keyword.get(opts, :header)
    }

  defp build_service(host, type, cred, _opts),
    do: %{host: host, auth_type: type, credential_key: cred, header: nil}
end
