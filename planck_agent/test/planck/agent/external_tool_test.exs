defmodule Planck.Agent.ExternalToolTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Planck.Agent.ExternalTool

  @valid_spec %{
    "name" => "echo_tool",
    "description" => "Echoes a message.",
    "command" => "echo {{message}}",
    "parameters" => %{
      "type" => "object",
      "properties" => %{"message" => %{"type" => "string"}},
      "required" => ["message"]
    }
  }

  defp write_tool(dir, name, spec) do
    tool_dir = Path.join(dir, name)
    File.mkdir_p!(tool_dir)
    path = Path.join(tool_dir, "TOOL.json")
    File.write!(path, Jason.encode!(spec))
    path
  end

  # --- from_file/1 ---

  describe "from_file/1" do
    test "returns {:ok, tool} for a valid TOOL.json", %{tmp_dir: dir} do
      path = write_tool(dir, "echo_tool", @valid_spec)
      assert {:ok, tool} = ExternalTool.from_file(path)
      assert tool.name == "echo_tool"
      assert tool.description == "Echoes a message."
      assert is_function(tool.execute_fn, 2)
    end

    test "returns error for a missing file" do
      assert {:error, reason} = ExternalTool.from_file("/no/such/TOOL.json")
      assert reason =~ "cannot read"
    end

    test "returns error for invalid JSON", %{tmp_dir: dir} do
      tool_dir = Path.join(dir, "bad")
      File.mkdir_p!(tool_dir)
      File.write!(Path.join(tool_dir, "TOOL.json"), "not json {")
      assert {:error, reason} = ExternalTool.from_file(Path.join(tool_dir, "TOOL.json"))
      assert reason =~ "invalid JSON"
    end

    test "returns error when required fields are missing", %{tmp_dir: dir} do
      path = write_tool(dir, "incomplete", %{"name" => "x"})
      assert {:error, reason} = ExternalTool.from_file(path)
      assert reason =~ "missing required fields"
    end

    test "execute_fn interpolates {{key}} placeholders", %{tmp_dir: dir} do
      path = write_tool(dir, "echo_tool", @valid_spec)
      {:ok, tool} = ExternalTool.from_file(path)
      {:ok, output} = tool.execute_fn.("id", %{"message" => "hello"})
      assert String.trim(output) == "hello"
    end

    test "execute_fn replaces unknown placeholders with empty string", %{tmp_dir: dir} do
      spec = Map.put(@valid_spec, "command", "echo {{missing}}")
      path = write_tool(dir, "empty_tool", spec)
      {:ok, tool} = ExternalTool.from_file(path)
      {:ok, output} = tool.execute_fn.("id", %{})
      assert String.trim(output) == ""
    end

    test "execute_fn returns error on non-zero exit", %{tmp_dir: dir} do
      spec = Map.put(@valid_spec, "command", "exit 1")
      path = write_tool(dir, "failing_tool", spec)
      {:ok, tool} = ExternalTool.from_file(path)
      assert {:error, reason} = tool.execute_fn.("id", %{})
      assert reason =~ "1"
    end
  end

  # --- load_all/1 ---

  describe "load_all/1" do
    test "loads all tools from a directory", %{tmp_dir: dir} do
      write_tool(dir, "tool_a", %{@valid_spec | "name" => "tool_a", "command" => "echo a"})
      write_tool(dir, "tool_b", %{@valid_spec | "name" => "tool_b", "command" => "echo b"})

      tools = ExternalTool.load_all([dir])
      names = tools |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["tool_a", "tool_b"]
    end

    test "loads from multiple directories", %{tmp_dir: dir} do
      dir_a = Path.join(dir, "a")
      dir_b = Path.join(dir, "b")
      File.mkdir_p!(dir_a)
      File.mkdir_p!(dir_b)

      write_tool(dir_a, "tool_a", %{@valid_spec | "name" => "tool_a", "command" => "echo a"})
      write_tool(dir_b, "tool_b", %{@valid_spec | "name" => "tool_b", "command" => "echo b"})

      tools = ExternalTool.load_all([dir_a, dir_b])
      names = tools |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["tool_a", "tool_b"]
    end

    test "skips missing directories" do
      assert ExternalTool.load_all(["/no/such/dir"]) == []
    end

    test "skips subdirectories without TOOL.json", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "not_a_tool"))
      assert ExternalTool.load_all([dir]) == []
    end

    test "skips malformed TOOL.json entries", %{tmp_dir: dir} do
      bad_dir = Path.join(dir, "bad_tool")
      File.mkdir_p!(bad_dir)
      File.write!(Path.join(bad_dir, "TOOL.json"), "not json")
      assert ExternalTool.load_all([dir]) == []
    end
  end
end
