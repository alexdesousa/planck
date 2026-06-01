defmodule Planck.Headless.Application do
  @moduledoc false

  use Application

  alias Planck.Headless.{Config, Supervisor}

  @impl true
  def start(_type, _args) do
    Config.preload()
    Config.validate!()
    configure_proxy_env()
    Supervisor.start_link()
  end

  # Set standard proxy env vars so the bash tool and sidecar inherit them.
  defp configure_proxy_env do
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
  end
end
