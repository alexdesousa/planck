defmodule Planck.Web.API.ModelControllerTest do
  use Planck.Web.ConnCase, async: false

  alias Planck.Headless
  alias Planck.Headless.Config

  # ---------------------------------------------------------------------------
  # GET /api/models
  # ---------------------------------------------------------------------------

  describe "index/2" do
    test "returns an empty list when no models are configured", %{conn: conn} do
      conn = get(conn, "/api/models")
      body = json_response(conn, 200)

      assert_schema(body, "ModelList", api_spec())
      assert is_list(body)
    end

    test "returns configured local models", %{conn: conn} do
      original = Application.get_env(:planck, :models)

      Application.put_env(:planck, :models, [
        %{
          "id" => "llama3.2",
          "provider" => "ollama",
          "base_url" => "http://localhost:11434",
          "context_window" => 128_000
        }
      ])

      Config.reload_models()
      Headless.reload_resources()

      on_exit(fn ->
        Application.delete_env(:planck, :models)
        if original, do: Application.put_env(:planck, :models, original)
        Config.reload_models()
        Headless.reload_resources()
      end)

      conn = get(conn, "/api/models")
      body = json_response(conn, 200)

      assert_schema(body, "ModelList", api_spec())
      assert [model] = Enum.filter(body, &(&1["id"] == "llama3.2"))
      assert model["provider"] == "ollama"
      assert model["context_window"] == 128_000
      assert model["base_url"] == "http://localhost:11434"
    end
  end
end
