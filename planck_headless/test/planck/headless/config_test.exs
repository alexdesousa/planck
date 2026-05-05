defmodule Planck.Headless.ConfigTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Planck.Headless.Config
  alias Planck.Headless.Config.{EnvBinding, JsonBinding}

  defp write_config(dir, data) do
    path = Path.join(dir, "config.json")
    File.write!(path, Jason.encode!(data))
    path
  end

  defp write_env(dir, pairs) do
    path = Path.join(dir, ".env")
    content = Enum.map_join(pairs, "\n", fn {k, v} -> "#{k}=#{v}" end)
    File.write!(path, content)
    path
  end

  defp env_for(key), do: Skogsra.Env.new(nil, :planck, key, [])

  defp api_env_for(:anthropic_api_key),
    do: Skogsra.Env.new(nil, :planck, :anthropic_api_key, os_env: "ANTHROPIC_API_KEY")

  defp api_env_for(:openai_api_key),
    do: Skogsra.Env.new(nil, :planck, :openai_api_key, os_env: "OPENAI_API_KEY")

  # --- Config.get/0 ---

  describe "get/0" do
    test "returns struct with the declared defaults" do
      config = Config.get()

      assert %Config{} = config
      assert config.default_provider == nil
      assert config.default_model == nil
      assert config.sessions_dir == ".planck/sessions"
      assert config.skills_dirs == [".planck/skills", "~/.planck/skills"]
      assert config.teams_dirs == [".planck/teams", "~/.planck/teams"]
      assert config.sidecar == ".planck/sidecar"
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

  # --- EnvBinding ---

  describe "EnvBinding" do
    setup do
      on_exit(fn ->
        Application.put_env(:planck_headless, :skip_env_config, true)
        Application.delete_env(:planck, :env_files)
        Config.reload_env_files()
        EnvBinding.invalidate()
      end)

      :ok
    end

    defp enable_env(path) do
      Application.put_env(:planck_headless, :skip_env_config, false)
      Application.put_env(:planck, :env_files, [path])
      Config.reload_env_files()
      EnvBinding.invalidate()
    end

    test "init/1 parses a .env file and returns a map", %{tmp_dir: dir} do
      path = write_env(dir, [{"ANTHROPIC_API_KEY", "sk-ant-test"}])
      enable_env(path)

      {:ok, env} = EnvBinding.init(api_env_for(:anthropic_api_key))
      assert env["ANTHROPIC_API_KEY"] == "sk-ant-test"
    end

    test "get_env/2 looks up the os_env name", %{tmp_dir: dir} do
      path = write_env(dir, [{"ANTHROPIC_API_KEY", "sk-ant-value"}])
      enable_env(path)

      env = api_env_for(:anthropic_api_key)
      {:ok, dotenv} = EnvBinding.init(env)
      assert {:ok, "sk-ant-value"} = EnvBinding.get_env(env, dotenv)
    end

    test "get_env/2 returns :error for absent keys", %{tmp_dir: dir} do
      path = write_env(dir, [{"OTHER_KEY", "val"}])
      enable_env(path)

      env = api_env_for(:anthropic_api_key)
      {:ok, dotenv} = EnvBinding.init(env)
      assert {:error, :not_found} = EnvBinding.get_env(env, dotenv)
    end

    test "strips double quotes from values", %{tmp_dir: dir} do
      path = write_env(dir, [{"ANTHROPIC_API_KEY", "\"sk-quoted\""}])
      enable_env(path)

      env = api_env_for(:anthropic_api_key)
      {:ok, dotenv} = EnvBinding.init(env)
      assert {:ok, "sk-quoted"} = EnvBinding.get_env(env, dotenv)
    end

    test "strips single quotes from values", %{tmp_dir: dir} do
      path = write_env(dir, [{"ANTHROPIC_API_KEY", "'sk-single'"}])
      enable_env(path)

      env = api_env_for(:anthropic_api_key)
      {:ok, dotenv} = EnvBinding.init(env)
      assert {:ok, "sk-single"} = EnvBinding.get_env(env, dotenv)
    end

    test "ignores comment lines and blank lines", %{tmp_dir: dir} do
      path = Path.join(dir, ".env")
      File.write!(path, "# comment\n\nANTHROPIC_API_KEY=sk-clean\n")
      enable_env(path)

      env = api_env_for(:anthropic_api_key)
      {:ok, dotenv} = EnvBinding.init(env)
      assert {:ok, "sk-clean"} = EnvBinding.get_env(env, dotenv)
      refute Map.has_key?(dotenv, "")
    end

    test "later file wins on key collision (project-local overrides global)", %{tmp_dir: dir} do
      global = write_env(dir, [{"ANTHROPIC_API_KEY", "global-key"}])
      local_dir = Path.join(dir, "project")
      File.mkdir_p!(local_dir)
      local = write_env(local_dir, [{"ANTHROPIC_API_KEY", "local-key"}])

      Application.put_env(:planck_headless, :skip_env_config, false)
      Application.put_env(:planck, :env_files, [global, local])
      Config.reload_env_files()
      EnvBinding.invalidate()

      env = api_env_for(:anthropic_api_key)
      {:ok, dotenv} = EnvBinding.init(env)
      assert {:ok, "local-key"} = EnvBinding.get_env(env, dotenv)
    end

    test "missing file is silently skipped", %{tmp_dir: dir} do
      path = write_env(dir, [{"OPENAI_API_KEY", "sk-open"}])
      nonexistent = Path.join(dir, "missing.env")

      Application.put_env(:planck_headless, :skip_env_config, false)
      Application.put_env(:planck, :env_files, [nonexistent, path])
      Config.reload_env_files()
      EnvBinding.invalidate()

      env = api_env_for(:openai_api_key)
      {:ok, dotenv} = EnvBinding.init(env)
      assert {:ok, "sk-open"} = EnvBinding.get_env(env, dotenv)
    end

    test "invalidate/0 clears the cache", %{tmp_dir: dir} do
      path = write_env(dir, [{"ANTHROPIC_API_KEY", "before"}])
      enable_env(path)

      EnvBinding.init(api_env_for(:anthropic_api_key))
      write_env(dir, [{"ANTHROPIC_API_KEY", "after"}])
      EnvBinding.invalidate()

      {:ok, dotenv} = EnvBinding.init(api_env_for(:anthropic_api_key))
      assert dotenv["ANTHROPIC_API_KEY"] == "after"
    end

    test "skip_env_config: true causes init/1 to return :error" do
      Application.put_env(:planck_headless, :skip_env_config, true)
      assert :error = EnvBinding.init(api_env_for(:anthropic_api_key))
    end
  end
end
