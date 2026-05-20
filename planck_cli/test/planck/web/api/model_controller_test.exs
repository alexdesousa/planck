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
      original_providers = Application.get_env(:planck, :providers)
      original_models = Application.get_env(:planck, :models)

      Application.put_env(:planck, :providers, %{
        "local" => %{
          "type" => "openai",
          "base_url" => "http://localhost:11434",
          "has_api_key" => false
        }
      })

      Application.put_env(:planck, :models, [
        %{"id" => "llama3.2", "model" => "llama3.2", "provider" => "local"}
      ])

      Config.reload_providers()
      Config.reload_models()
      Headless.reload_resources()

      on_exit(fn ->
        Application.delete_env(:planck, :providers)
        Application.delete_env(:planck, :models)
        if original_providers, do: Application.put_env(:planck, :providers, original_providers)
        if original_models, do: Application.put_env(:planck, :models, original_models)
        Config.reload_providers()
        Config.reload_models()
        Headless.reload_resources()
      end)

      conn = get(conn, "/api/models")
      body = json_response(conn, 200)

      assert_schema(body, "ModelList", api_spec())
      assert [model] = Enum.filter(body, &(&1["id"] == "llama3.2"))
      assert model["provider"] == "openai"
      assert model["base_url"] == "http://localhost:11434"
    end
  end
end
