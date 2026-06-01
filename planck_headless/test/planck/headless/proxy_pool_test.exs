defmodule Planck.Headless.ProxyPoolTest do
  use ExUnit.Case, async: false

  alias Planck.Headless.{Config, ProxyPool}

  setup do
    on_exit(fn ->
      Application.delete_env(:planck, :tool_proxy)
      Application.delete_env(:planck, :tool_proxy_ca_cert)
      Config.reload_tool_proxy()
      Config.reload_tool_proxy_ca_cert()
      System.delete_env("HTTP_PROXY")
      System.delete_env("HTTPS_PROXY")
      System.delete_env("http_proxy")
      System.delete_env("https_proxy")
      System.delete_env("SSL_CERT_FILE")
      System.delete_env("CURL_CA_BUNDLE")
      System.delete_env("REQUESTS_CA_BUNDLE")
      System.delete_env("NODE_EXTRA_CA_CERTS")
    end)

    :ok
  end

  defp set_proxy(url) do
    Application.put_env(:planck, :tool_proxy, url)
    Config.reload_tool_proxy()
  end

  defp set_ca_cert(path) do
    Application.put_env(:planck, :tool_proxy_ca_cert, path)
    Config.reload_tool_proxy_ca_cert()
  end

  # ---------------------------------------------------------------------------
  # opts/0
  # ---------------------------------------------------------------------------

  describe "opts/0" do
    test "returns empty list when no proxy configured" do
      assert ProxyPool.opts() == []
    end

    test "returns finch_name when proxy configured" do
      set_proxy("http://vault:14322")
      assert ProxyPool.opts() == [finch_name: ProxyPool.name()]
    end
  end

  # ---------------------------------------------------------------------------
  # child_spec/0
  # ---------------------------------------------------------------------------

  describe "child_spec/0" do
    test "returns nil when no proxy configured" do
      assert ProxyPool.child_spec() == nil
    end

    test "returns a child spec when proxy configured" do
      set_proxy("http://vault:14322")
      spec = ProxyPool.child_spec()
      assert is_map(spec)
      assert spec.id == ProxyPool.name()
    end

    test "parses http scheme and host/port correctly" do
      set_proxy("http://myproxy:8080")
      spec = ProxyPool.child_spec()
      assert spec != nil
      {_mod, :start_link, [opts]} = spec.start
      proxy = get_in(opts, [:pools, :default, :conn_opts, :proxy])
      assert proxy == {:http, "myproxy", 8080, []}
    end

    test "parses https scheme correctly" do
      set_proxy("https://secureproxy:443")
      spec = ProxyPool.child_spec()
      {_mod, :start_link, [opts]} = spec.start
      proxy = get_in(opts, [:pools, :default, :conn_opts, :proxy])
      assert proxy == {:https, "secureproxy", 443, []}
    end

    test "includes cacertfile in transport_opts when ca_cert configured" do
      set_proxy("http://vault:14322")
      set_ca_cert("/certs/ca.pem")
      spec = ProxyPool.child_spec()
      {_mod, :start_link, [opts]} = spec.start
      transport_opts = get_in(opts, [:pools, :default, :conn_opts, :transport_opts])
      assert transport_opts[:cacertfile] == "/certs/ca.pem"
    end

    test "no transport_opts when no ca_cert" do
      set_proxy("http://vault:14322")
      spec = ProxyPool.child_spec()
      {_mod, :start_link, [opts]} = spec.start
      transport_opts = get_in(opts, [:pools, :default, :conn_opts, :transport_opts])
      assert transport_opts == nil
    end
  end

  # ---------------------------------------------------------------------------
  # configure_os_env/0
  # ---------------------------------------------------------------------------

  describe "configure_os_env/0" do
    test "does nothing when no proxy configured" do
      ProxyPool.configure_os_env()
      assert System.get_env("HTTP_PROXY") == nil
      assert System.get_env("HTTPS_PROXY") == nil
    end

    test "sets HTTP_PROXY and HTTPS_PROXY when proxy configured" do
      set_proxy("http://vault:14322")
      ProxyPool.configure_os_env()
      assert System.get_env("HTTP_PROXY") == "http://vault:14322"
      assert System.get_env("HTTPS_PROXY") == "http://vault:14322"
      assert System.get_env("http_proxy") == "http://vault:14322"
      assert System.get_env("https_proxy") == "http://vault:14322"
    end

    test "does not set cert vars when no ca_cert configured" do
      set_proxy("http://vault:14322")
      ProxyPool.configure_os_env()
      assert System.get_env("SSL_CERT_FILE") == nil
      assert System.get_env("CURL_CA_BUNDLE") == nil
    end

    test "sets all cert env vars when ca_cert configured" do
      set_proxy("http://vault:14322")
      set_ca_cert("/certs/ca.pem")
      ProxyPool.configure_os_env()
      assert System.get_env("SSL_CERT_FILE") == "/certs/ca.pem"
      assert System.get_env("CURL_CA_BUNDLE") == "/certs/ca.pem"
      assert System.get_env("REQUESTS_CA_BUNDLE") == "/certs/ca.pem"
      assert System.get_env("NODE_EXTRA_CA_CERTS") == "/certs/ca.pem"
    end
  end
end
