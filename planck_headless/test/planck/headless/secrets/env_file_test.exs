defmodule Planck.Headless.Secrets.EnvFileTest do
  use ExUnit.Case, async: false

  alias Planck.Headless.Secrets.EnvFile

  # Each test gets its own isolated directory so tests can run concurrently.
  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "env-file-test-#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    # Point the module's relative paths inside the tmp dir by running
    # assertions with File.cd!/2.
    {:ok, tmp: tmp}
  end

  defp cd(tmp, fun), do: File.cd!(tmp, fun)

  defp local(tmp), do: Path.join([tmp, ".planck", ".env"])
  defp global(_tmp), do: Path.join([Path.expand("~"), ".planck", ".env"])

  defp write!(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  # ---------------------------------------------------------------------------
  # store/2
  # ---------------------------------------------------------------------------

  describe "store/2" do
    test "creates the file and writes the key", %{tmp: tmp} do
      cd(tmp, fn ->
        assert :ok = EnvFile.store("MY_KEY", "my-value")
        assert File.read!(local(tmp)) =~ "MY_KEY=my-value"
      end)
    end

    test "updates an existing key in-place", %{tmp: tmp} do
      cd(tmp, fn ->
        EnvFile.store("KEY", "old")
        EnvFile.store("KEY", "new")
        content = File.read!(local(tmp))
        assert content =~ "KEY=new"
        refute content =~ "KEY=old"
        assert length(String.split(content, "\n", trim: true)) == 1
      end)
    end

    test "preserves existing service rule comments", %{tmp: tmp} do
      cd(tmp, fn ->
        EnvFile.store_service("api.n8n.com", "bearer", "N8N_API_KEY", [])
        EnvFile.store("OTHER_KEY", "value")
        content = File.read!(local(tmp))
        assert content =~ "OTHER_KEY=value"
        assert content =~ "# planck-service: api.n8n.com bearer N8N_API_KEY"
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # fetch/1
  # ---------------------------------------------------------------------------

  describe "fetch/1" do
    test "returns value from local file", %{tmp: tmp} do
      cd(tmp, fn ->
        EnvFile.store("API_KEY", "secret")
        assert {:ok, "secret"} = EnvFile.fetch("API_KEY")
      end)
    end

    test "returns :not_found when key absent", %{tmp: tmp} do
      cd(tmp, fn -> assert :not_found = EnvFile.fetch("MISSING") end)
    end

    test "returns :not_found when no files exist", %{tmp: tmp} do
      cd(tmp, fn -> assert :not_found = EnvFile.fetch("ANY") end)
    end
  end

  # ---------------------------------------------------------------------------
  # list/0
  # ---------------------------------------------------------------------------

  describe "list/0" do
    test "returns all credential keys, excluding service comments", %{tmp: tmp} do
      cd(tmp, fn ->
        EnvFile.store("KEY_A", "1")
        EnvFile.store("KEY_B", "2")
        EnvFile.store_service("api.n8n.com", "bearer", "KEY_A", [])
        assert {:ok, keys} = EnvFile.list()
        assert Enum.sort(keys) == ["KEY_A", "KEY_B"]
      end)
    end

    test "returns empty list when no files exist", %{tmp: tmp} do
      cd(tmp, fn -> assert {:ok, []} = EnvFile.list() end)
    end
  end

  # ---------------------------------------------------------------------------
  # delete/1
  # ---------------------------------------------------------------------------

  describe "delete/1" do
    test "removes key from local file", %{tmp: tmp} do
      cd(tmp, fn ->
        EnvFile.store("KEY", "val")
        assert :ok = EnvFile.delete("KEY")
        assert :not_found = EnvFile.fetch("KEY")
      end)
    end

    test "also removes service rules that reference the deleted key", %{tmp: tmp} do
      cd(tmp, fn ->
        EnvFile.store("N8N_API_KEY", "secret")
        EnvFile.store_service("api.n8n.com", "bearer", "N8N_API_KEY", [])
        EnvFile.delete("N8N_API_KEY")
        content = File.read!(local(tmp))
        refute content =~ "N8N_API_KEY"
        refute content =~ "planck-service"
      end)
    end

    test "only removes service rules for the deleted key, not others", %{tmp: tmp} do
      cd(tmp, fn ->
        EnvFile.store("KEY_A", "val")
        EnvFile.store("KEY_B", "val")
        EnvFile.store_service("api.a.com", "bearer", "KEY_A", [])
        EnvFile.store_service("api.b.com", "bearer", "KEY_B", [])
        EnvFile.delete("KEY_A")
        content = File.read!(local(tmp))
        refute content =~ "KEY_A"
        refute content =~ "api.a.com"
        assert content =~ "KEY_B=val"
        assert content =~ "api.b.com"
      end)
    end

    test "no-op when key does not exist", %{tmp: tmp} do
      cd(tmp, fn -> assert :ok = EnvFile.delete("NONEXISTENT") end)
    end
  end

  # ---------------------------------------------------------------------------
  # fetch_all/0
  # ---------------------------------------------------------------------------

  describe "fetch_all/0" do
    test "returns map of all credentials", %{tmp: tmp} do
      cd(tmp, fn ->
        EnvFile.store("A", "1")
        EnvFile.store("B", "2")
        assert %{"A" => "1", "B" => "2"} = EnvFile.fetch_all()
      end)
    end

    test "local file overrides global for same key", %{tmp: tmp} do
      global = global(tmp)

      # Only run if global file doesn't already exist (avoid polluting real env)
      unless File.exists?(global) do
        write!(global, "SHARED=global-value\n")

        cd(tmp, fn ->
          EnvFile.store("SHARED", "local-value")
          assert %{"SHARED" => "local-value"} = EnvFile.fetch_all()
        end)

        File.rm!(global)
      end
    end

    test "does not include service rule lines in result", %{tmp: tmp} do
      cd(tmp, fn ->
        EnvFile.store("MY_KEY", "val")
        EnvFile.store_service("api.n8n.com", "bearer", "MY_KEY", [])
        all = EnvFile.fetch_all()
        assert Map.has_key?(all, "MY_KEY")
        refute Enum.any?(Map.keys(all), &String.starts_with?(&1, "#"))
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # store_service/4
  # ---------------------------------------------------------------------------

  describe "store_service/4" do
    test "writes bearer service rule as comment line", %{tmp: tmp} do
      cd(tmp, fn ->
        assert :ok = EnvFile.store_service("api.n8n.com", "bearer", "N8N_API_KEY", [])
        content = File.read!(local(tmp))
        assert content =~ "# planck-service: api.n8n.com bearer N8N_API_KEY"
      end)
    end

    test "writes api-key service rule with header", %{tmp: tmp} do
      cd(tmp, fn ->
        assert :ok =
                 EnvFile.store_service("api.anthropic.com", "api-key", "ANTHROPIC_API_KEY",
                   header: "x-api-key"
                 )

        content = File.read!(local(tmp))

        assert content =~
                 "# planck-service: api.anthropic.com api-key x-api-key ANTHROPIC_API_KEY"
      end)
    end

    test "upserts — replaces existing rule for the same host", %{tmp: tmp} do
      cd(tmp, fn ->
        EnvFile.store_service("api.n8n.com", "bearer", "OLD_KEY", [])
        EnvFile.store_service("api.n8n.com", "bearer", "NEW_KEY", [])
        content = File.read!(local(tmp))
        assert content =~ "NEW_KEY"
        refute content =~ "OLD_KEY"
        assert length(Enum.filter(String.split(content, "\n"), &(&1 =~ "planck-service"))) == 1
      end)
    end

    test "preserves existing credentials when writing service rule", %{tmp: tmp} do
      cd(tmp, fn ->
        EnvFile.store("MY_KEY", "secret")
        EnvFile.store_service("api.n8n.com", "bearer", "MY_KEY", [])
        content = File.read!(local(tmp))
        assert content =~ "MY_KEY=secret"
        assert content =~ "# planck-service: api.n8n.com bearer MY_KEY"
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # delete_service/1
  # ---------------------------------------------------------------------------

  describe "delete_service/1" do
    test "removes the service rule comment line", %{tmp: tmp} do
      cd(tmp, fn ->
        EnvFile.store_service("api.n8n.com", "bearer", "N8N_API_KEY", [])
        assert :ok = EnvFile.delete_service("api.n8n.com")
        refute File.read!(local(tmp)) =~ "planck-service"
      end)
    end

    test "preserves credentials when deleting service rule", %{tmp: tmp} do
      cd(tmp, fn ->
        EnvFile.store("N8N_API_KEY", "secret")
        EnvFile.store_service("api.n8n.com", "bearer", "N8N_API_KEY", [])
        EnvFile.delete_service("api.n8n.com")
        content = File.read!(local(tmp))
        assert content =~ "N8N_API_KEY=secret"
        refute content =~ "planck-service"
      end)
    end

    test "no-op when host does not exist", %{tmp: tmp} do
      cd(tmp, fn -> assert :ok = EnvFile.delete_service("api.gone.com") end)
    end
  end

  # ---------------------------------------------------------------------------
  # list_services/0
  # ---------------------------------------------------------------------------

  describe "list_services/0" do
    test "returns parsed service list", %{tmp: tmp} do
      cd(tmp, fn ->
        EnvFile.store_service("api.n8n.com", "bearer", "N8N_API_KEY", [])

        EnvFile.store_service("api.custom.com", "api-key", "CUSTOM_KEY", header: "x-api-key")

        assert {:ok, services} = EnvFile.list_services()
        assert length(services) == 2

        n8n = Enum.find(services, &(&1.host == "api.n8n.com"))
        assert n8n.auth_type == "bearer"
        assert n8n.credential_key == "N8N_API_KEY"
        assert is_nil(n8n.header)

        custom = Enum.find(services, &(&1.host == "api.custom.com"))
        assert custom.auth_type == "api-key"
        assert custom.credential_key == "CUSTOM_KEY"
        assert custom.header == "x-api-key"
      end)
    end

    test "returns empty list when no files exist", %{tmp: tmp} do
      cd(tmp, fn -> assert {:ok, []} = EnvFile.list_services() end)
    end
  end

  # ---------------------------------------------------------------------------
  # write_to/3
  # ---------------------------------------------------------------------------

  describe "write_to/3" do
    test "writes to the specified path", %{tmp: tmp} do
      path = Path.join(tmp, "custom/.env")
      assert :ok = EnvFile.write_to(path, "KEY", "value")
      assert File.read!(path) =~ "KEY=value"
    end

    test "preserves service comments on the target path", %{tmp: tmp} do
      cd(tmp, fn ->
        path = ".planck/.env"
        EnvFile.store_service("api.n8n.com", "bearer", "N8N_KEY", [])
        EnvFile.write_to(path, "OTHER", "val")
        content = File.read!(local(tmp))
        assert content =~ "OTHER=val"
        assert content =~ "# planck-service: api.n8n.com bearer N8N_KEY"
      end)
    end
  end
end
