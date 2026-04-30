defmodule Planck.Headless.ConfigTest do
  use ExUnit.Case, async: false

  alias Planck.Headless.Config

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
end
