defmodule Planck.Headless.ProxyPool do
  @moduledoc """
  Manages an optional Finch HTTP pool configured to route requests through
  the tool proxy (e.g. agent-vault).

  When `tool_proxy` is set in config, `child_spec/0` returns a `Finch` child
  spec with proxy and CA cert settings. Pass `finch_name: ProxyPool.name()` in
  agent opts so `req_llm` routes LLM API calls through the proxy.

  When no proxy is configured, `child_spec/0` returns `nil` and `opts/0`
  returns `[]`, so callers are unaffected.
  """

  alias Planck.Headless.Config

  @name __MODULE__

  @doc "The registered name of the proxy Finch pool."
  @spec name() :: atom()
  def name, do: @name

  @doc """
  Returns `[finch_name: ProxyPool.name()]` when a proxy is configured, `[]`
  otherwise. Merge into agent opts so `req_llm` uses the proxy pool.
  """
  @spec opts() :: keyword()
  def opts do
    if Config.tool_proxy!(), do: [finch_name: @name], else: []
  end

  @doc """
  Returns a Finch child spec configured with the tool proxy and CA cert, or
  `nil` when no proxy is set. Used by the application supervisor.
  """
  @spec child_spec() :: Supervisor.child_spec() | nil
  def child_spec do
    case Config.tool_proxy!() do
      nil ->
        nil

      proxy_url ->
        %URI{scheme: scheme, host: host, port: port} = URI.parse(proxy_url)
        pool_opts = build_pool_opts(String.to_atom(scheme), host, port)

        Supervisor.child_spec(
          {Finch, name: @name, pools: %{:default => pool_opts}},
          id: @name
        )
    end
  end

  @doc """
  Sets standard proxy environment variables so child processes (bash tools,
  sidecar, etc.) inherit them. Called at application start when a proxy is set.
  """
  @spec configure_os_env() :: :ok
  def configure_os_env do
    if proxy = Config.tool_proxy!() do
      System.put_env("HTTP_PROXY", proxy)
      System.put_env("HTTPS_PROXY", proxy)
      System.put_env("http_proxy", proxy)
      System.put_env("https_proxy", proxy)
    end

    if ca_cert = Config.tool_proxy_ca_cert!() do
      System.put_env("SSL_CERT_FILE", ca_cert)
      System.put_env("CURL_CA_BUNDLE", ca_cert)
      System.put_env("REQUESTS_CA_BUNDLE", ca_cert)
      System.put_env("NODE_EXTRA_CA_CERTS", ca_cert)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec build_pool_opts(atom(), String.t(), pos_integer()) :: keyword()
  defp build_pool_opts(scheme, host, port) do
    conn_opts =
      [proxy: {scheme, host, port, []}]
      |> maybe_add_ca_cert()

    [conn_opts: conn_opts]
  end

  @spec maybe_add_ca_cert(keyword()) :: keyword()
  defp maybe_add_ca_cert(conn_opts) do
    case Config.tool_proxy_ca_cert!() do
      nil -> conn_opts
      path -> Keyword.put(conn_opts, :transport_opts, cacertfile: path)
    end
  end
end
