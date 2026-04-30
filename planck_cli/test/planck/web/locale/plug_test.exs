defmodule Planck.Web.Locale.PlugTest do
  use Planck.Web.ConnCase, async: false

  alias Planck.Web.Locale.Plug, as: LocalePlug

  @opts LocalePlug.init(gettext: Planck.Web.Gettext, locales: ["en", "es"])

  # init_test_session/2 fetches the Plug session so get_session/2 works.
  setup %{conn: conn} do
    {:ok, conn: Plug.Test.init_test_session(conn, %{})}
  end

  describe "call/2" do
    test "assigns selected locale to conn", %{conn: conn} do
      conn =
        conn
        |> Map.put(:req_headers, [{"accept-language", "es"}])
        |> LocalePlug.call(@opts)

      assert conn.assigns.locale == "es"
    end

    test "stores selected locale in session", %{conn: conn} do
      conn =
        conn
        |> Map.put(:req_headers, [{"accept-language", "es"}])
        |> LocalePlug.call(@opts)

      assert Plug.Conn.get_session(conn, :locale) == "es"
    end

    test "sets Gettext process locale", %{conn: conn} do
      conn
      |> Map.put(:req_headers, [{"accept-language", "es"}])
      |> LocalePlug.call(@opts)

      assert Gettext.get_locale(Planck.Web.Gettext) == "es"
    end

    test "falls back to first locale when no preference", %{conn: conn} do
      conn = LocalePlug.call(conn, @opts)
      assert conn.assigns.locale == "en"
    end

    test "respects ?locale= query param", %{conn: conn} do
      conn =
        conn
        |> Map.put(:params, %{"locale" => "es"})
        |> LocalePlug.call(@opts)

      assert conn.assigns.locale == "es"
    end

    test "session locale is used as default when no Accept-Language header", %{conn: conn} do
      # When the client sends no Accept-Language preference, the previously
      # stored session locale is chosen as the default.
      conn =
        conn
        |> Plug.Conn.put_session(:locale, "es")
        |> LocalePlug.call(@opts)

      assert conn.assigns.locale == "es"
    end
  end
end
