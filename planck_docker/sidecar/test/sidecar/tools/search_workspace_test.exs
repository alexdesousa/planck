defmodule Sidecar.Tools.SearchWorkspaceTest do
  use ExUnit.Case, async: false

  alias Sidecar.{Config, Tools.SearchWorkspace}

  setup do
    bypass = Bypass.open()
    Application.put_env(:sidecar, :typesense_url, "http://localhost:#{bypass.port}")
    Application.put_env(:sidecar, :typesense_api_key, "test-key")
    Config.reload_typesense_url()
    Config.reload_typesense_api_key()

    on_exit(fn ->
      Application.delete_env(:sidecar, :typesense_url)
      Application.delete_env(:sidecar, :typesense_api_key)
      Config.reload_typesense_url()
      Config.reload_typesense_api_key()
    end)

    {:ok, bypass: bypass}
  end

  test "returns formatted results on success", %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/collections/workspace/documents/search", fn conn ->
      body =
        Jason.encode!(%{
          "hits" => [
            %{"document" => %{"path" => "lib/foo.ex", "content" => "defmodule Foo do"}}
          ]
        })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, body)
    end)

    assert {:ok, result} = SearchWorkspace.search("foo")
    assert result =~ "lib/foo.ex"
    assert result =~ "defmodule Foo"
  end

  test "returns no results message on empty hits", %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/collections/workspace/documents/search", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"hits" => []}))
    end)

    assert {:ok, "No results found."} = SearchWorkspace.search("nothing")
  end

  test "returns error when Typesense is unreachable" do
    Application.put_env(:sidecar, :typesense_url, "http://localhost:1")
    Config.reload_typesense_url()

    assert {:error, _msg} = SearchWorkspace.search("query")
  end
end
