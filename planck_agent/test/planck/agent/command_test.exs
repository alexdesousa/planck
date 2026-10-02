defmodule Planck.Agent.CommandTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Planck.Agent.Command

  defp write_command(dir, name, content) do
    command_dir = Path.join(dir, name)
    File.mkdir_p!(command_dir)
    command_file = Path.join(command_dir, "COMMAND.md")
    File.write!(command_file, content)
    {command_dir, command_file}
  end

  defp valid_md(name, description) do
    """
    ---
    name: #{name}
    description: #{description}
    ---

    # #{String.capitalize(name)}

    You are an expert. Args: <%= args %>
    """
  end

  describe "from_file/1" do
    test "parses a valid COMMAND.md", %{tmp_dir: dir} do
      {command_dir, command_file} =
        write_command(dir, "review-checklist", valid_md("review-checklist", "Reviews code."))

      {:ok, command} = Command.from_file(command_file)

      assert command.name == "review-checklist"
      assert command.description == "Reviews code."
      assert command.path == command_dir
      assert command.command_file == command_file
      assert command.disable_model_invocation == true
      assert command.help == nil
      assert command.template =~ "You are an expert. Args: <%= args %>"
    end

    test "parses disable-model-invocation: false", %{tmp_dir: dir} do
      content = """
      ---
      name: auto-cmd
      description: Auto-invokable.
      disable-model-invocation: false
      ---

      Body.
      """

      {_, command_file} = write_command(dir, "auto-cmd", content)

      {:ok, command} = Command.from_file(command_file)
      assert command.disable_model_invocation == false
    end

    test "disable-model-invocation defaults to true when absent", %{tmp_dir: dir} do
      {_, command_file} = write_command(dir, "default-cmd", valid_md("default-cmd", "A command."))

      {:ok, command} = Command.from_file(command_file)
      assert command.disable_model_invocation == true
    end

    test "non-boolean disable-model-invocation normalizes to true", %{tmp_dir: dir} do
      content = """
      ---
      name: bad-cmd
      description: Has a malformed value.
      disable-model-invocation: "yes"
      ---

      Body.
      """

      {_, command_file} = write_command(dir, "bad-cmd", content)

      {:ok, command} = Command.from_file(command_file)
      assert command.disable_model_invocation == true
    end

    test "parses help field when present", %{tmp_dir: dir} do
      content = """
      ---
      name: review-checklist
      description: Reviews code.
      help: "/review-checklist [scope]"
      ---

      Body.
      """

      {_, command_file} = write_command(dir, "review-checklist", content)

      {:ok, command} = Command.from_file(command_file)
      assert command.help == "/review-checklist [scope]"
    end

    test "help defaults to nil when absent", %{tmp_dir: dir} do
      {_, command_file} = write_command(dir, "no-help", valid_md("no-help", "No help."))

      {:ok, command} = Command.from_file(command_file)
      assert command.help == nil
    end

    test "template is stored raw, not rendered at load time", %{tmp_dir: dir} do
      content = """
      ---
      name: tmpl
      description: Template test.
      ---

      You are reviewing: <%= args %>
      """

      {_, command_file} = write_command(dir, "tmpl", content)

      {:ok, command} = Command.from_file(command_file)
      assert command.template =~ "<%= args %>"
    end

    test "returns error for missing name", %{tmp_dir: dir} do
      content = """
      ---
      description: No name.
      ---

      Body.
      """

      {_, command_file} = write_command(dir, "no-name", content)

      assert {:error, reason} = Command.from_file(command_file)
      assert reason =~ "missing required frontmatter field 'name'"
    end

    test "returns error for missing description", %{tmp_dir: dir} do
      content = """
      ---
      name: no-desc
      ---

      Body.
      """

      {_, command_file} = write_command(dir, "no-desc", content)

      assert {:error, reason} = Command.from_file(command_file)
      assert reason =~ "missing required frontmatter field 'description'"
    end

    test "returns error for file without frontmatter", %{tmp_dir: dir} do
      {_, command_file} = write_command(dir, "no-frontmatter", "Just some text.")

      assert {:error, reason} = Command.from_file(command_file)
      assert reason =~ "has no frontmatter"
    end
  end

  describe "load_all/1" do
    test "loads commands from multiple directories", %{tmp_dir: dir} do
      dir1 = Path.join(dir, "dir1")
      dir2 = Path.join(dir, "dir2")
      File.mkdir_p!(dir1)
      File.mkdir_p!(dir2)

      write_command(dir1, "cmd-a", valid_md("cmd-a", "Command A."))
      write_command(dir2, "cmd-b", valid_md("cmd-b", "Command B."))

      commands = Command.load_all([dir1, dir2])

      names = Enum.map(commands, & &1.name) |> Enum.sort()
      assert names == ["cmd-a", "cmd-b"]
    end

    test "skips directories without COMMAND.md", %{tmp_dir: dir} do
      empty_dir = Path.join(dir, "empty")
      File.mkdir_p!(empty_dir)

      commands = Command.load_all([empty_dir])
      assert commands == []
    end

    test "skips directories that do not exist" do
      commands = Command.load_all(["/nonexistent/path/commands"])
      assert commands == []
    end

    test "skips malformed frontmatter with a warning", %{tmp_dir: dir} do
      bad_dir = Path.join(dir, "bad")
      File.mkdir_p!(bad_dir)

      write_command(bad_dir, "good", valid_md("good", "Good command."))

      bad_content = """
      ---
      description: No name.
      ---

      Body.
      """

      write_command(bad_dir, "bad", bad_content)

      commands = Command.load_all([bad_dir])

      assert length(commands) == 1
      assert hd(commands).name == "good"
    end
  end

  describe "COMMAND.md sentinel" do
    test "a directory with SKILL.md but no COMMAND.md is not loaded", %{tmp_dir: dir} do
      skill_dir = Path.join(dir, "my-skill")
      File.mkdir_p!(skill_dir)
      File.write!(Path.join(skill_dir, "SKILL.md"), valid_md("my-skill", "A skill."))

      commands = Command.load_all([dir])
      assert commands == []
    end
  end
end
