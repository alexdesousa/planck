defmodule Planck.Web.Locale.HeaderTest do
  use ExUnit.Case, async: true

  alias Planck.Web.Locale.Header

  # ---------------------------------------------------------------------------
  # locale/1 — Accept-Language parsing
  # ---------------------------------------------------------------------------

  describe "locale/1" do
    test "parses a simple language tag" do
      assert [%{language: "en", tags: []}] = Header.locale("en")
    end

    test "parses a language tag with region subtag" do
      assert [%{language: "en", tags: ["us"]}] = Header.locale("en-US")
    end

    test "sorts by quality weight descending" do
      result = Header.locale("en;q=0.5, fr;q=0.9, de;q=0.7")
      assert Enum.map(result, & &1.language) == ["fr", "de", "en"]
    end

    test "implicit weight of 1.0 beats explicit lower weights" do
      result = Header.locale("es, en;q=0.8")
      assert hd(result).language == "es"
    end

    test "wildcard * is parsed as language *" do
      assert [%{language: "*"}] = Header.locale("*")
    end

    test "multiple tags are all returned" do
      result = Header.locale("en, fr, de")
      languages = Enum.map(result, & &1.language)
      assert "en" in languages
      assert "fr" in languages
      assert "de" in languages
    end
  end

  # ---------------------------------------------------------------------------
  # merge/2 — best-match selection
  # ---------------------------------------------------------------------------

  describe "merge/2" do
    test "returns exact match when available" do
      requested = Header.locale("fr")
      offered = Header.locale("en,fr")
      assert Header.merge(requested, offered) == "fr"
    end

    test "matches on language tag ignoring region" do
      requested = Header.locale("en-US")
      offered = Header.locale("en")
      assert Header.merge(requested, offered) == "en"
    end

    test "returns highest-priority match when multiple offered" do
      requested = Header.locale("es-ES,es;q=0.9,en;q=0.8")
      offered = Header.locale("en,es")
      assert Header.merge(requested, offered) == "es"
    end

    test "returns nil when no match in offered" do
      requested = Header.locale("zh")
      offered = Header.locale("en,es")
      assert Header.merge(requested, offered) == nil
    end

    test "returns nil when offered is empty" do
      requested = Header.locale("en")
      assert Header.merge(requested, []) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # client_locale/2 — conn extraction
  # ---------------------------------------------------------------------------

  describe "client_locale/2" do
    test "reads locale from ?locale= query param" do
      conn = build_conn(%{params: %{"locale" => "es"}})
      offered = Header.locale("en,es")
      result = Header.client_locale(conn, offered)
      assert Enum.any?(result, &(&1.language == "es"))
    end

    test "reads locale from Accept-Language header" do
      conn =
        build_conn(%{})
        |> Map.put(:req_headers, [{"accept-language", "fr"}])

      offered = Header.locale("en,fr")
      result = Header.client_locale(conn, offered)
      assert Enum.any?(result, &(&1.language == "fr"))
    end

    test "falls back to first offered when no header or param" do
      conn = build_conn(%{})
      offered = Header.locale("en,es")
      result = Header.client_locale(conn, offered)
      assert Enum.any?(result, &(&1.language == "en"))
    end

    test "?locale= takes precedence over Accept-Language header" do
      conn =
        build_conn(%{params: %{"locale" => "es"}})
        |> Map.put(:req_headers, [{"accept-language", "en"}])

      offered = Header.locale("en,es")
      result = Header.client_locale(conn, offered)
      # es should appear before en in the result
      languages = Enum.map(result, & &1.language)

      assert Enum.find_index(languages, &(&1 == "es")) <
               Enum.find_index(languages, &(&1 == "en"))
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_conn(overrides) do
    defaults = %{
      params: %{},
      req_headers: [],
      path_info: [],
      query_string: ""
    }

    struct(Plug.Conn, Map.merge(defaults, overrides))
  end
end
