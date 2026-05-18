defmodule Sidecar.Tools.SearchWebTest do
  use ExUnit.Case, async: false

  alias Sidecar.{Config, Tools.SearchWeb}

  setup do
    bypass = Bypass.open()
    Application.put_env(:sidecar, :searxng_url, "http://localhost:#{bypass.port}")
    Config.reload_searxng_url()

    on_exit(fn ->
      Application.delete_env(:sidecar, :searxng_url)
      Config.reload_searxng_url()
    end)

    {:ok, bypass: bypass}
  end

  test "returns formatted results on success", %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/search", fn conn ->
      body =
        Jason.encode!(%{
          "results" => [
            %{
              "title" => "Elixir Lang",
              "url" => "https://elixir-lang.org",
              "content" => "A dynamic language for building scalable applications."
            }
          ]
        })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, body)
    end)

    assert {:ok, result} = SearchWeb.search("elixir language")
    assert result =~ "Elixir Lang"
    assert result =~ "https://elixir-lang.org"
  end

  test "returns no results message on empty results", %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/search", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"results" => []}))
    end)

    assert {:ok, "No results found."} = SearchWeb.search("xyzzy")
  end

  test "returns error when Searxng is unreachable" do
    Application.put_env(:sidecar, :searxng_url, "http://localhost:1")
    Config.reload_searxng_url()

    assert {:error, _msg} = SearchWeb.search("query")
  end
end
