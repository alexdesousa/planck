defmodule Planck.Web.API.ProxyControllerTest do
  use Planck.Web.ConnCase, async: false

  @moduletag :tmp_dir

  alias Planck.CLI.Config

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp put_domains(domains) do
    orig_sys = System.get_env("PLANCK_PROXY_IMAGE_DOMAINS")
    orig_app = Application.get_env(:planck_cli, :proxy_image_domains)
    System.delete_env("PLANCK_PROXY_IMAGE_DOMAINS")
    Application.put_env(:planck_cli, :proxy_image_domains, domains)
    Config.reload_proxy_image_domains()

    on_exit(fn ->
      if orig_sys, do: System.put_env("PLANCK_PROXY_IMAGE_DOMAINS", orig_sys)

      if orig_app,
        do: Application.put_env(:planck_cli, :proxy_image_domains, orig_app),
        else: Application.delete_env(:planck_cli, :proxy_image_domains)

      Config.reload_proxy_image_domains()
    end)
  end

  defp put_paths(paths) do
    orig_sys = System.get_env("PLANCK_PROXY_IMAGE_PATHS")
    orig_app = Application.get_env(:planck_cli, :proxy_image_paths)
    System.delete_env("PLANCK_PROXY_IMAGE_PATHS")
    Application.put_env(:planck_cli, :proxy_image_paths, paths)
    Config.reload_proxy_image_paths()

    on_exit(fn ->
      if orig_sys, do: System.put_env("PLANCK_PROXY_IMAGE_PATHS", orig_sys)

      if orig_app,
        do: Application.put_env(:planck_cli, :proxy_image_paths, orig_app),
        else: Application.delete_env(:planck_cli, :proxy_image_paths)

      Config.reload_proxy_image_paths()
    end)
  end

  defp proxy_url(url), do: "/api/proxy?url=#{URI.encode_www_form(url)}"

  # ---------------------------------------------------------------------------
  # file:// — allowed paths
  # ---------------------------------------------------------------------------

  describe "image/2 with file:// URL" do
    test "serves file when path is under an allowed prefix", %{conn: conn, tmp_dir: dir} do
      path = Path.join(dir, "img.png")
      File.write!(path, "PNG_DATA")
      put_paths([dir])

      conn = get(conn, proxy_url("file://#{path}"))

      assert response(conn, 200) == "PNG_DATA"
      assert get_resp_header(conn, "content-type") == ["image/png; charset=utf-8"]
    end

    test "returns 403 when path is not in the allowlist", %{conn: conn, tmp_dir: dir} do
      File.write!(Path.join(dir, "img.png"), "PNG_DATA")
      put_paths([])

      conn = get(conn, proxy_url("file://#{dir}/img.png"))

      assert response(conn, 403)
    end

    test "returns 403 for path traversal that escapes the allowed prefix", %{
      conn: conn,
      tmp_dir: dir
    } do
      safe_dir = Path.join(dir, "safe")
      File.mkdir_p!(safe_dir)
      File.write!(Path.join(dir, "secret.txt"), "SECRET")
      put_paths([safe_dir])

      conn = get(conn, proxy_url("file://#{safe_dir}/../secret.txt"))

      assert response(conn, 403)
    end

    test "returns 404 when the file does not exist", %{conn: conn, tmp_dir: dir} do
      put_paths([dir])

      conn = get(conn, proxy_url("file://#{dir}/missing.png"))

      assert response(conn, 404)
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP/HTTPS — allowlist enforcement
  # ---------------------------------------------------------------------------

  describe "image/2 with HTTP/HTTPS URL — deny cases" do
    test "returns 403 when domain is not in the allowlist", %{conn: conn} do
      put_domains([])

      conn = get(conn, proxy_url("https://evil.com/img.png"))

      assert response(conn, 403)
    end

    test "returns 403 for non-http/https schemes even if host matches", %{conn: conn} do
      put_domains(["evil.com"])

      conn = get(conn, proxy_url("ftp://evil.com/img.png"))

      assert response(conn, 403)
    end

    test "returns 403 by default (empty domain list)", %{conn: conn} do
      conn = get(conn, proxy_url("https://example.com/img.png"))

      assert response(conn, 403)
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP — success path via Bypass
  # ---------------------------------------------------------------------------

  describe "image/2 with HTTP URL — success" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass}
    end

    test "proxies image and forwards content-type", %{conn: conn, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/img.png", fn c ->
        c
        |> Plug.Conn.put_resp_header("content-type", "image/png")
        |> Plug.Conn.send_resp(200, "PNG_DATA")
      end)

      put_domains(["localhost"])
      url = "http://localhost:#{bypass.port}/img.png"

      conn = get(conn, proxy_url(url))

      assert response(conn, 200) == "PNG_DATA"
      assert get_resp_header(conn, "content-type") == ["image/png; charset=utf-8"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=3600"]
    end

    test "strips charset from upstream content-type before forwarding", %{
      conn: conn,
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "GET", "/img.jpeg", fn c ->
        c
        |> Plug.Conn.put_resp_header("content-type", "image/jpeg; charset=utf-8")
        |> Plug.Conn.send_resp(200, "JPEG_DATA")
      end)

      put_domains(["localhost"])
      url = "http://localhost:#{bypass.port}/img.jpeg"

      conn = get(conn, proxy_url(url))

      assert response(conn, 200) == "JPEG_DATA"
      assert get_resp_header(conn, "content-type") == ["image/jpeg; charset=utf-8"]
    end

    test "falls back to application/octet-stream when upstream omits content-type", %{
      conn: conn,
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "GET", "/file.bin", fn c ->
        Plug.Conn.send_resp(c, 200, "BINARY")
      end)

      put_domains(["localhost"])
      url = "http://localhost:#{bypass.port}/file.bin"

      conn = get(conn, proxy_url(url))

      assert response(conn, 200) == "BINARY"
      assert get_resp_header(conn, "content-type") == ["application/octet-stream; charset=utf-8"]
    end

    test "forwards non-200 status from upstream", %{conn: conn, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/gone.png", fn c ->
        Plug.Conn.send_resp(c, 404, "")
      end)

      put_domains(["localhost"])
      url = "http://localhost:#{bypass.port}/gone.png"

      conn = get(conn, proxy_url(url))

      assert response(conn, 404)
    end

    test "returns 502 when upstream is unreachable", %{conn: conn, bypass: bypass} do
      Bypass.down(bypass)
      put_domains(["localhost"])
      url = "http://localhost:#{bypass.port}/img.png"

      conn = get(conn, proxy_url(url))

      assert response(conn, 502)
    end
  end
end
