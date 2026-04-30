defmodule Planck.Headless.ConfigTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Planck.Headless.Config
  alias Planck.Headless.Config.JsonBinding

  defp write_config(dir, data) do
    path = Path.join(dir, "config.json")
    File.write!(path, Jason.encode!(data))
    path
  end

  defp env_for(key), do: Skogsra.Env.new(nil, :planck, key, [])

  # --- Config.get/0 ---

  describe "get/0" do
    test "returns struct with the declared defaults" do
      config = Config.get()

      assert %Config{} = config
      assert config.default_provider == nil
      assert config.default_model == nil
      assert config.sessions_dir == ".planck/sessions"
      assert config.skills_dirs == [".planck/skills", "~/.planck/skills"]
      assert config.tools_dirs == [".planck/tools", "~/.planck/tools"]
      assert config.teams_dirs == [".planck/teams", "~/.planck/teams"]
      assert config.compactor == nil
      assert config.models == []
    end
  end

  describe "application-env overrides" do
    setup do
      on_exit(fn ->
        Application.delete_env(:planck, :default_model)
        Config.reload_default_model()
      end)

      :ok
    end

    test "picked up after reload" do
      Application.put_env(:planck, :default_model, "claude-sonnet-4-6")
      Config.reload_default_model()

      assert Config.get().default_model == "claude-sonnet-4-6"
    end
  end

  # --- JsonBinding ---

  describe "JsonBinding" do
    setup do
      on_exit(fn ->
        Application.put_env(:planck_headless, :skip_json_config, true)
        Application.delete_env(:planck, :config_files)
        Config.reload_config_files()
        JsonBinding.invalidate()
      end)

      :ok
    end

    test "init/1 returns a map from the config file", %{tmp_dir: dir} do
      path = write_config(dir, %{"default_model" => "test-model"})
      Application.put_env(:planck_headless, :skip_json_config, false)
      Application.put_env(:planck, :config_files, [path])
      Config.reload_config_files()
      JsonBinding.invalidate()

      {:ok, config} = JsonBinding.init(env_for(:default_model))
      assert config["default_model"] == "test-model"
    end

    test "get_env/2 returns the value for the matching key", %{tmp_dir: dir} do
      path = write_config(dir, %{"default_model" => "from-json"})
      Application.put_env(:planck_headless, :skip_json_config, false)
      Application.put_env(:planck, :config_files, [path])
      Config.reload_config_files()
      JsonBinding.invalidate()

      env = env_for(:default_model)
      {:ok, config} = JsonBinding.init(env)

      assert {:ok, "from-json"} = JsonBinding.get_env(env, config)
    end

    test "get_env/2 returns :error for unknown keys", %{tmp_dir: dir} do
      path = write_config(dir, %{"other_key" => "val"})
      Application.put_env(:planck_headless, :skip_json_config, false)
      Application.put_env(:planck, :config_files, [path])
      Config.reload_config_files()
      JsonBinding.invalidate()

      env = env_for(:default_model)
      {:ok, config} = JsonBinding.init(env)

      assert {:error, :not_found} = JsonBinding.get_env(env, config)
    end

    test "later files override earlier ones (project-local wins)", %{tmp_dir: dir} do
      global = write_config(dir, %{"default_model" => "from-global"})
      local_path = Path.join(dir, "local.json")
      File.write!(local_path, Jason.encode!(%{"default_model" => "from-local"}))

      Application.put_env(:planck_headless, :skip_json_config, false)
      Application.put_env(:planck, :config_files, [global, local_path])
      Config.reload_config_files()
      JsonBinding.invalidate()

      {:ok, config} = JsonBinding.init(env_for(:default_model))
      assert config["default_model"] == "from-local"
    end

    test "missing files are silently skipped", %{tmp_dir: _dir} do
      Application.put_env(:planck_headless, :skip_json_config, false)
      Application.put_env(:planck, :config_files, ["/no/such/file.json"])
      Config.reload_config_files()
      JsonBinding.invalidate()

      assert {:ok, %{}} = JsonBinding.init(env_for(:default_model))
    end

    test "malformed JSON is skipped with a warning", %{tmp_dir: dir} do
      path = Path.join(dir, "bad.json")
      File.write!(path, "not json {{{")
      Application.put_env(:planck_headless, :skip_json_config, false)
      Application.put_env(:planck, :config_files, [path])
      Config.reload_config_files()
      JsonBinding.invalidate()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{}} = JsonBinding.init(env_for(:default_model))
        end)

      assert log =~ "invalid JSON"
    end

    test "results are cached — file is read only once", %{tmp_dir: dir} do
      path = write_config(dir, %{"default_model" => "cached"})
      Application.put_env(:planck_headless, :skip_json_config, false)
      Application.put_env(:planck, :config_files, [path])
      Config.reload_config_files()
      JsonBinding.invalidate()

      {:ok, config1} = JsonBinding.init(env_for(:default_model))
      File.write!(path, Jason.encode!(%{"default_model" => "updated"}))
      {:ok, config2} = JsonBinding.init(env_for(:default_model))

      assert config1["default_model"] == "cached"
      assert config2["default_model"] == "cached"
    end

    test "invalidate/0 clears the cache", %{tmp_dir: dir} do
      path = write_config(dir, %{"default_model" => "before"})
      Application.put_env(:planck_headless, :skip_json_config, false)
      Application.put_env(:planck, :config_files, [path])
      Config.reload_config_files()
      JsonBinding.invalidate()

      JsonBinding.init(env_for(:default_model))
      File.write!(path, Jason.encode!(%{"default_model" => "after"}))
      JsonBinding.invalidate()

      {:ok, config} = JsonBinding.init(env_for(:default_model))
      assert config["default_model"] == "after"
    end
  end
end
