defmodule Planck.Web.Locale.ConfigTest do
  use ExUnit.Case, async: false

  alias Planck.Web.Locale.Config

  # ---------------------------------------------------------------------------
  # new/1
  # ---------------------------------------------------------------------------

  describe "new/1" do
    test "requires :gettext" do
      assert_raise ArgumentError, fn ->
        Config.new(locales: ["en"])
      end
    end

    test "requires :locales" do
      assert_raise ArgumentError, fn ->
        Config.new(gettext: Planck.Web.Gettext)
      end
    end

    test "builds a valid config" do
      config = Config.new(gettext: Planck.Web.Gettext, locales: ["en", "es"])
      assert config.gettext == Planck.Web.Gettext
      assert config.redirect == false
    end

    test "parses locales into locale structs" do
      config = Config.new(gettext: Planck.Web.Gettext, locales: ["en", "es"])
      languages = Enum.map(config.locales, & &1.language)
      assert "en" in languages
      assert "es" in languages
    end
  end

  # ---------------------------------------------------------------------------
  # select_locale/2 — priority chain
  # ---------------------------------------------------------------------------

  describe "select_locale/2" do
    test "selects locale from ?locale= param" do
      conn = build_conn(%{params: %{"locale" => "es"}})
      config = Config.new(gettext: Planck.Web.Gettext, locales: ["en", "es"])
      result = Config.select_locale(conn, config)
      assert result.selected == "es"
    end

    test "selects locale from Accept-Language header" do
      conn =
        build_conn(%{})
        |> Map.put(:req_headers, [{"accept-language", "es"}])

      config = Config.new(gettext: Planck.Web.Gettext, locales: ["en", "es"])
      result = Config.select_locale(conn, config)
      assert result.selected == "es"
    end

    test "falls back to first locale when no preference expressed" do
      conn = build_conn(%{})
      config = Config.new(gettext: Planck.Web.Gettext, locales: ["en", "es"])
      result = Config.select_locale(conn, config)
      assert result.selected == "en"
    end

    test "ignores unknown locale from config.json" do
      original = Application.get_env(:planck, :locale)
      Application.put_env(:planck, :locale, "zh")
      Planck.Headless.Config.reload_locale()

      on_exit(fn ->
        Application.delete_env(:planck, :locale)
        if original, do: Application.put_env(:planck, :locale, original)
        Planck.Headless.Config.reload_locale()
      end)

      conn = build_conn(%{})
      config = Config.new(gettext: Planck.Web.Gettext, locales: ["en", "es"])
      result = Config.select_locale(conn, config)
      # zh is not offered — falls back to the header/default
      assert result.selected == "en"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_conn(overrides) do
    defaults = %{params: %{}, req_headers: []}
    conn = struct(Plug.Conn, Map.merge(defaults, overrides))
    Plug.Test.init_test_session(conn, %{})
  end
end
