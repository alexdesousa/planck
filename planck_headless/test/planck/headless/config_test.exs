defmodule Planck.Headless.ConfigTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Planck.Headless.Config

  @keys ~w(default_provider default_model sessions_dir skills_dirs tools_dirs teams_dirs compactor)a

  setup do
    original = Enum.map(@keys, fn k -> {k, Application.get_env(:planck_headless, k)} end)
    Enum.each(@keys, &Application.delete_env(:planck_headless, &1))

    on_exit(fn ->
      Enum.each(@keys, &Application.delete_env(:planck_headless, &1))

      Enum.each(original, fn
        {_k, nil} -> :ok
        {k, v} -> Application.put_env(:planck_headless, k, v)
      end)

      Application.put_env(:planck_headless, :config_files, [])
    end)

    :ok
  end

  defp write_config(dir, filename, map) do
    path = Path.join(dir, filename)
    File.write!(path, Jason.encode!(map))
    path
  end

  # --- get/0 ---

  describe "get/0" do
    test "returns struct with defaults when nothing is configured" do
      Enum.each(@keys, &Application.delete_env(:planck_headless, &1))

      config = Config.get()

      assert config.default_provider == nil
      assert config.default_model == nil
      assert config.sessions_dir == ".planck/sessions"
      assert config.skills_dirs == [".planck/skills", "~/.planck/skills"]
      assert config.tools_dirs == [".planck/tools", "~/.planck/tools"]
      assert config.teams_dirs == [".planck/teams", "~/.planck/teams"]
      assert config.compactor == nil
    end

    test "picks up application-env overrides" do
      Application.put_env(:planck_headless, :default_provider, :anthropic)
      Application.put_env(:planck_headless, :default_model, "claude-sonnet-4-6")
      Application.put_env(:planck_headless, :sessions_dir, "/custom/sessions")

      config = Config.get()

      assert config.default_provider == :anthropic
      assert config.default_model == "claude-sonnet-4-6"
      assert config.sessions_dir == "/custom/sessions"
    end
  end

  # --- load/0 ---

  describe "load/0" do
    test "merges known keys from a single JSON file into app env", %{tmp_dir: dir} do
      path =
        write_config(dir, "config.json", %{
          "default_provider" => "anthropic",
          "default_model" => "claude-sonnet-4-6",
          "sessions_dir" => "/from-json/sessions",
          "teams_dirs" => ["/from-json/teams"]
        })

      Application.put_env(:planck_headless, :config_files, [path])
      assert :ok = Config.load()

      config = Config.get()
      assert config.default_provider == :anthropic
      assert config.default_model == "claude-sonnet-4-6"
      assert config.sessions_dir == "/from-json/sessions"
      assert config.teams_dirs == ["/from-json/teams"]
    end

    test "later files override earlier ones (project overrides global)", %{tmp_dir: dir} do
      global = write_config(dir, "global.json", %{"default_model" => "from-global"})
      project = write_config(dir, "project.json", %{"default_model" => "from-project"})

      Application.put_env(:planck_headless, :config_files, [global, project])
      Config.load()

      assert Config.get().default_model == "from-project"
    end

    test "missing files are silently skipped" do
      Application.put_env(:planck_headless, :config_files, ["/definitely/not/a/real/path.json"])
      assert :ok = Config.load()
    end

    test "malformed JSON is skipped with a warning", %{tmp_dir: dir} do
      path = Path.join(dir, "bad.json")
      File.write!(path, "not json {{{")

      Application.put_env(:planck_headless, :config_files, [path])

      assert ExUnit.CaptureLog.capture_log(fn -> Config.load() end) =~ "invalid JSON"
    end

    test "unknown keys are logged and ignored", %{tmp_dir: dir} do
      path = write_config(dir, "config.json", %{"bogus_key" => "value"})
      Application.put_env(:planck_headless, :config_files, [path])

      log = ExUnit.CaptureLog.capture_log(fn -> Config.load() end)
      assert log =~ "unknown key \"bogus_key\""
      assert Application.get_env(:planck_headless, :bogus_key) == nil
    end

    test "non-object JSON is rejected with a warning", %{tmp_dir: dir} do
      path = Path.join(dir, "array.json")
      File.write!(path, Jason.encode!([1, 2, 3]))
      Application.put_env(:planck_headless, :config_files, [path])

      assert ExUnit.CaptureLog.capture_log(fn -> Config.load() end) =~ "must be a JSON object"
    end

    test "is idempotent", %{tmp_dir: dir} do
      path = write_config(dir, "config.json", %{"default_model" => "v1"})
      Application.put_env(:planck_headless, :config_files, [path])

      Config.load()
      Config.load()

      assert Config.get().default_model == "v1"
    end
  end
end
