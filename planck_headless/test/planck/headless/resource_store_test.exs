defmodule Planck.Headless.ResourceStoreTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Planck.Headless.{Config, ResourceStore}

  defp write_team(teams_dir, alias_name) do
    team_dir = Path.join(teams_dir, alias_name)
    File.mkdir_p!(team_dir)

    File.write!(
      Path.join(team_dir, "TEAM.json"),
      Jason.encode!(%{
        "name" => alias_name,
        "members" => [
          %{
            "type" => "orchestrator",
            "provider" => "openai",
            "model_id" => "llama3.2",
            "system_prompt" => "You coordinate."
          }
        ]
      })
    )
  end

  # Ensure the teams_dirs config and ResourceStore state are restored after each test.
  setup do
    on_exit(fn ->
      Application.delete_env(:planck, :teams_dirs)
      Config.reload_teams_dirs()
      ResourceStore.reload()
    end)

    :ok
  end

  # --- get/0 ---

  describe "get/0" do
    test "returns a ResourceStore struct" do
      assert %ResourceStore{} = ResourceStore.get()
    end

    test "has expected field types" do
      store = ResourceStore.get()
      assert is_list(store.tools)
      assert is_list(store.skills)
      assert is_map(store.teams)
      assert is_list(store.available_models)
    end
  end

  # --- reload/0 with teams ---

  describe "reload/0" do
    test "loads teams from configured dirs", %{tmp_dir: dir} do
      write_team(dir, "my-team")
      Application.put_env(:planck, :teams_dirs, [dir])
      Config.reload_teams_dirs()
      :ok = ResourceStore.reload()

      assert Map.has_key?(ResourceStore.get().teams, "my-team")
    end

    test "later dir wins on alias collision (project-local overrides global)", %{tmp_dir: dir} do
      global_dir = Path.join(dir, "global")
      local_dir = Path.join(dir, "local")
      write_team(global_dir, "shared")
      write_team(local_dir, "shared")

      Application.put_env(:planck, :teams_dirs, [global_dir, local_dir])
      Config.reload_teams_dirs()
      :ok = ResourceStore.reload()

      team = ResourceStore.get().teams["shared"]
      assert team.dir == Path.expand(Path.join(local_dir, "shared"))
    end

    test "dirs that do not exist are silently skipped", %{tmp_dir: dir} do
      Application.put_env(:planck, :teams_dirs, [Path.join(dir, "nonexistent")])
      Config.reload_teams_dirs()
      :ok = ResourceStore.reload()

      assert ResourceStore.get().teams == %{}
    end

    test "malformed team dirs are skipped with a warning", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "bad-team"))
      Application.put_env(:planck, :teams_dirs, [dir])
      Config.reload_teams_dirs()

      log = ExUnit.CaptureLog.capture_log(fn -> ResourceStore.reload() end)
      assert log =~ "skipping"
    end

    test "available_models is populated from providers + models config", %{tmp_dir: _dir} do
      on_exit(fn ->
        Application.delete_env(:planck, :providers)
        Application.delete_env(:planck, :models)
        Config.reload_providers()
        Config.reload_models()
        ResourceStore.reload()
      end)

      Application.put_env(:planck, :providers, %{
        "anthropic" => %{"type" => "anthropic"},
        "local" => %{"type" => "openai", "base_url" => "http://localhost:11434", "has_api_key" => false}
      })

      Application.put_env(:planck, :models, [
        %{"id" => "sonnet", "model" => "claude-sonnet-4-6", "provider" => "anthropic"},
        %{"id" => "llama3.2", "model" => "llama3.2", "provider" => "local"}
      ])

      Config.reload_providers()
      Config.reload_models()
      :ok = ResourceStore.reload()

      models = ResourceStore.get().available_models
      assert length(models) == 2
      ids = Enum.map(models, & &1.id)
      assert "sonnet" in ids
      assert "llama3.2" in ids
    end

    test "models with unknown provider key are skipped", %{tmp_dir: _dir} do
      on_exit(fn ->
        Application.delete_env(:planck, :providers)
        Application.delete_env(:planck, :models)
        Config.reload_providers()
        Config.reload_models()
        ResourceStore.reload()
      end)

      Application.put_env(:planck, :providers, %{"anthropic" => %{"type" => "anthropic"}})

      Application.put_env(:planck, :models, [
        %{"id" => "sonnet", "model" => "claude-sonnet-4-6", "provider" => "anthropic"},
        %{"id" => "orphan", "model" => "some-model", "provider" => "no-such-provider"}
      ])

      Config.reload_providers()
      Config.reload_models()

      log = ExUnit.CaptureLog.capture_log(fn -> ResourceStore.reload() end)

      models = ResourceStore.get().available_models
      assert length(models) == 1
      assert hd(models).id == "sonnet"
      assert log =~ "unknown provider key"
    end
  end

  # --- Planck.Headless public API ---

  describe "Planck.Headless.list_teams/0 and get_team/1" do
    test "list_teams/0 returns alias, name, description for loaded teams", %{tmp_dir: dir} do
      write_team(dir, "elixir-dev")
      Application.put_env(:planck, :teams_dirs, [dir])
      Config.reload_teams_dirs()
      ResourceStore.reload()

      teams = Planck.Headless.list_teams()
      assert Enum.any?(teams, &(&1.alias == "elixir-dev"))
    end

    test "get_team/1 returns {:ok, team} for known alias", %{tmp_dir: dir} do
      write_team(dir, "known-team")
      Application.put_env(:planck, :teams_dirs, [dir])
      Config.reload_teams_dirs()
      ResourceStore.reload()

      assert {:ok, team} = Planck.Headless.get_team("known-team")
      assert team.alias == "known-team"
    end

    test "get_team/1 returns {:error, :not_found} for unknown alias" do
      assert {:error, :not_found} = Planck.Headless.get_team("no-such-team")
    end
  end
end
