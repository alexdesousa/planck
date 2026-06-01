defmodule Sidecar.Secrets.AgentVaultTest do
  use ExUnit.Case, async: false

  alias Sidecar.{Config, Secrets.AgentVault}

  @vault "planck"
  @token "test-agent-token"

  setup do
    bypass = Bypass.open()
    Application.put_env(:sidecar, :agent_vault_url, "http://localhost:#{bypass.port}")
    Application.put_env(:sidecar, :agent_vault_token, @token)
    Application.put_env(:sidecar, :agent_vault_vault, @vault)
    Config.reload_agent_vault_url()
    Config.reload_agent_vault_token()
    Config.reload_agent_vault_vault()

    on_exit(fn ->
      Application.delete_env(:sidecar, :agent_vault_url)
      Application.delete_env(:sidecar, :agent_vault_token)
      Application.delete_env(:sidecar, :agent_vault_vault)
      Config.reload_agent_vault_url()
      Config.reload_agent_vault_token()
      Config.reload_agent_vault_vault()
    end)

    {:ok, bypass: bypass}
  end

  defp assert_auth(conn) do
    assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{@token}"]
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  # ---------------------------------------------------------------------------
  # store/2
  # ---------------------------------------------------------------------------

  describe "store/2" do
    test "posts credential to vault", %{bypass: bypass} do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v1/credentials", fn conn ->
        assert_auth(conn)
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:body, Jason.decode!(raw)})
        json(conn, 200, %{})
      end)

      assert :ok = AgentVault.store("MY_KEY", "my-value")
      assert_receive {:body, body}
      assert body["vault"] == @vault
      assert body["credentials"]["MY_KEY"] == "my-value"
    end

    test "returns error on 401", %{bypass: bypass} do
      Bypass.stub(bypass, "POST", "/v1/credentials", &json(&1, 401, %{}))
      assert {:error, :unauthorized} = AgentVault.store("K", "v")
    end

    test "returns error on unexpected status", %{bypass: bypass} do
      Bypass.stub(bypass, "POST", "/v1/credentials", &json(&1, 500, %{"error" => "internal"}))
      assert {:error, {:unexpected, 500, _}} = AgentVault.store("K", "v")
    end
  end

  # ---------------------------------------------------------------------------
  # fetch/1
  # ---------------------------------------------------------------------------

  describe "fetch/1" do
    test "returns value when credential exists", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v1/credentials", fn conn ->
        assert_auth(conn)
        json(conn, 200, %{"credentials" => [%{"key" => "MY_KEY", "value" => "secret"}]})
      end)

      assert {:ok, "secret"} = AgentVault.fetch("MY_KEY")
    end

    test "returns :not_found for empty list", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/v1/credentials", &json(&1, 200, %{"credentials" => []}))
      assert :not_found = AgentVault.fetch("MISSING")
    end

    test "returns :not_found for nil credentials", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/v1/credentials", &json(&1, 200, %{"credentials" => nil}))
      assert :not_found = AgentVault.fetch("MISSING")
    end

    test "returns :not_found on 404", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/v1/credentials", &json(&1, 404, %{}))
      assert :not_found = AgentVault.fetch("MISSING")
    end
  end

  # ---------------------------------------------------------------------------
  # list/0
  # ---------------------------------------------------------------------------

  describe "list/0" do
    test "returns list of credential keys", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v1/credentials", fn conn ->
        assert_auth(conn)
        json(conn, 200, %{"keys" => ["KEY_A", "KEY_B"]})
      end)

      assert {:ok, ["KEY_A", "KEY_B"]} = AgentVault.list()
    end

    test "returns empty list when no keys field", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/v1/credentials", &json(&1, 200, %{}))
      assert {:ok, []} = AgentVault.list()
    end
  end

  # ---------------------------------------------------------------------------
  # delete/1
  # ---------------------------------------------------------------------------

  describe "delete/1" do
    test "deletes credential and any service rules that reference it", %{bypass: bypass} do
      parent = self()

      Bypass.expect_once(bypass, "DELETE", "/v1/credentials", fn conn ->
        assert_auth(conn)
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:credential, Jason.decode!(raw)})
        json(conn, 200, %{})
      end)

      # list_services called to find rules referencing MY_KEY
      Bypass.expect_once(bypass, "GET", "/v1/vaults/#{@vault}/services", fn conn ->
        json(conn, 200, %{
          "services" => [
            %{"host" => "api.n8n.com", "auth" => %{"type" => "bearer", "key" => "MY_KEY"}},
            %{"host" => "api.other.com", "auth" => %{"type" => "bearer", "key" => "OTHER_KEY"}}
          ]
        })
      end)

      # Only the matching service rule is deleted
      Bypass.expect_once(bypass, "DELETE", "/v1/vaults/#{@vault}/services/api.n8n.com", fn conn ->
        send(parent, :service_deleted)
        json(conn, 200, %{})
      end)

      assert :ok = AgentVault.delete("MY_KEY")
      assert_receive {:credential, body}
      assert body["keys"] == ["MY_KEY"]
      assert_receive :service_deleted
    end

    test "succeeds even when listing services fails", %{bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/v1/credentials", &json(&1, 200, %{}))
      Bypass.expect_once(bypass, "GET", "/v1/vaults/#{@vault}/services", &json(&1, 500, %{}))

      assert :ok = AgentVault.delete("MY_KEY")
    end
  end

  # ---------------------------------------------------------------------------
  # store_service/4
  # ---------------------------------------------------------------------------

  describe "store_service/4" do
    test "creates a bearer service rule", %{bypass: bypass} do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v1/vaults/#{@vault}/services", fn conn ->
        assert_auth(conn)
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:body, Jason.decode!(raw)})
        json(conn, 200, %{})
      end)

      assert :ok = AgentVault.store_service("api.n8n.com", "bearer", "N8N_API_KEY", [])

      assert_receive {:body, body}
      assert [%{"host" => "api.n8n.com", "auth" => auth}] = body["services"]
      assert auth["type"] == "bearer"
      assert auth["key"] == "N8N_API_KEY"
      refute Map.has_key?(auth, "header")
    end

    test "creates an api-key service rule with header", %{bypass: bypass} do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v1/vaults/#{@vault}/services", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:body, Jason.decode!(raw)})
        json(conn, 200, %{})
      end)

      assert :ok =
               AgentVault.store_service("api.anthropic.com", "api-key", "ANTHROPIC_API_KEY",
                 header: "x-api-key"
               )

      assert_receive {:body, body}
      assert [%{"host" => "api.anthropic.com", "auth" => auth}] = body["services"]
      assert auth["type"] == "api-key"
      assert auth["key"] == "ANTHROPIC_API_KEY"
      assert auth["header"] == "x-api-key"
    end
  end

  # ---------------------------------------------------------------------------
  # delete_service/1
  # ---------------------------------------------------------------------------

  describe "delete_service/1" do
    test "deletes service rule by host", %{bypass: bypass} do
      Bypass.expect_once(
        bypass,
        "DELETE",
        "/v1/vaults/#{@vault}/services/api.n8n.com",
        fn conn ->
          assert_auth(conn)
          json(conn, 200, %{})
        end
      )

      assert :ok = AgentVault.delete_service("api.n8n.com")
    end

    test "returns :ok when rule does not exist (404)", %{bypass: bypass} do
      Bypass.stub(
        bypass,
        "DELETE",
        "/v1/vaults/#{@vault}/services/api.gone.com",
        &json(&1, 404, %{})
      )

      assert :ok = AgentVault.delete_service("api.gone.com")
    end
  end

  # ---------------------------------------------------------------------------
  # list_services/0
  # ---------------------------------------------------------------------------

  describe "list_services/0" do
    test "returns parsed service list", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v1/vaults/#{@vault}/services", fn conn ->
        assert_auth(conn)

        json(conn, 200, %{
          "services" => [
            %{"host" => "api.n8n.com", "auth" => %{"type" => "bearer", "key" => "N8N_API_KEY"}},
            %{
              "host" => "api.custom.com",
              "auth" => %{"type" => "api-key", "key" => "CUSTOM_KEY", "header" => "x-api-key"}
            }
          ]
        })
      end)

      assert {:ok, services} = AgentVault.list_services()
      assert length(services) == 2

      n8n = Enum.find(services, &(&1.host == "api.n8n.com"))
      assert n8n.auth_type == "bearer"
      assert n8n.credential_key == "N8N_API_KEY"
      assert is_nil(n8n.header)

      custom = Enum.find(services, &(&1.host == "api.custom.com"))
      assert custom.auth_type == "api-key"
      assert custom.credential_key == "CUSTOM_KEY"
      assert custom.header == "x-api-key"
    end

    test "returns empty list when no services", %{bypass: bypass} do
      Bypass.stub(
        bypass,
        "GET",
        "/v1/vaults/#{@vault}/services",
        &json(&1, 200, %{"services" => []})
      )

      assert {:ok, []} = AgentVault.list_services()
    end
  end

  # ---------------------------------------------------------------------------
  # maybe_migrate/0
  # ---------------------------------------------------------------------------

  describe "maybe_migrate/0" do
    # Override HOME so ~/.planck/.env resolves to an isolated tmp dir
    defp with_isolated_home(fun) do
      tmp = Path.join(System.tmp_dir!(), "av-home-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      original_home = System.get_env("HOME")
      System.put_env("HOME", tmp)

      try do
        fun.(tmp)
      after
        if original_home,
          do: System.put_env("HOME", original_home),
          else: System.delete_env("HOME")
      end
    end

    test "migrates credentials and service rules, then deletes .env", %{bypass: bypass} do
      parent = self()

      with_isolated_home(fn tmp ->
        env_file = Path.join([tmp, ".planck", ".env"])
        File.mkdir_p!(Path.dirname(env_file))

        File.write!(env_file, """
        N8N_API_KEY=secret-n8n
        CUSTOM_KEY=secret-custom
        # planck-service: api.n8n.com bearer N8N_API_KEY
        # planck-service: api.custom.com api-key x-api-key CUSTOM_KEY
        """)

        Bypass.stub(bypass, "POST", "/v1/credentials", fn conn ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(parent, {:credential, Jason.decode!(raw)["credentials"]})
          json(conn, 200, %{})
        end)

        Bypass.stub(bypass, "POST", "/v1/vaults/#{@vault}/services", fn conn ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(parent, {:service, hd(Jason.decode!(raw)["services"])})
          json(conn, 200, %{})
        end)

        File.cd!(tmp, fn -> AgentVault.maybe_migrate() end)

        creds =
          for _ <- 1..2 do
            assert_receive {:credential, c}, 1_000
            c
          end
          |> Enum.reduce(&Map.merge/2)

        assert creds["N8N_API_KEY"] == "secret-n8n"
        assert creds["CUSTOM_KEY"] == "secret-custom"

        hosts =
          for _ <- 1..2 do
            assert_receive {:service, s}, 1_000
            s["host"]
          end

        assert "api.n8n.com" in hosts
        assert "api.custom.com" in hosts
        refute File.exists?(env_file)
      end)
    end

    test "skips migration when no .env files exist" do
      with_isolated_home(fn tmp ->
        # No Bypass expectations — no HTTP calls should be made
        File.cd!(tmp, fn -> assert :ok = AgentVault.maybe_migrate() end)
      end)
    end
  end
end
