defmodule Planck.Agent.ToolTest do
  use ExUnit.Case, async: true

  alias Planck.Agent.{Tool, Tools}

  defp params,
    do: %{
      "type" => "object",
      "properties" => %{"path" => %{"type" => "string"}},
      "required" => ["path"]
    }

  defp execute_fn, do: fn _id, _args -> {:ok, :done} end

  describe "new/1" do
    test "builds a %Tool{} struct" do
      assert %Tool{} =
               Tool.new(
                 name: "read",
                 description: "Read a file",
                 parameters: params(),
                 execute_fn: execute_fn()
               )
    end

    test "sets all fields" do
      fun = execute_fn()

      tool =
        Tool.new(
          name: "read",
          description: "Read a file",
          parameters: params(),
          execute_fn: fun
        )

      assert tool.name == "read"
      assert tool.description == "Read a file"
      assert tool.parameters == params()
      assert tool.execute_fn == fun
    end
  end

  describe "to_ai_tool/1" do
    test "returns a Planck.AI.Tool with matching name, description, parameters" do
      tool =
        Tool.new(
          name: "read",
          description: "Read a file",
          parameters: params(),
          execute_fn: execute_fn()
        )

      ai_tool = Tool.to_ai_tool(tool)

      assert %Planck.AI.Tool{} = ai_tool
      assert ai_tool.name == tool.name
      assert ai_tool.description == tool.description
      assert ai_tool.parameters == tool.parameters
    end

    test "drops execute_fn" do
      tool =
        Tool.new(
          name: "read",
          description: "Read a file",
          parameters: params(),
          execute_fn: execute_fn()
        )

      ai_tool = Tool.to_ai_tool(tool)
      refute Map.has_key?(ai_tool, :execute_fn)
    end
  end

  describe "Tools.prepend_agents_md/2" do
    @tag :tmp_dir
    test "prepends AGENTS.md content to system prompt", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "AGENTS.md"), "Project rules.")
      result = Tools.prepend_agents_md("You implement.", dir)
      assert result == "Project rules.\n\nYou implement."
    end

    @tag :tmp_dir
    test "returns AGENTS.md content when system prompt is empty", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "AGENTS.md"), "Project rules.")
      assert Tools.prepend_agents_md("", dir) == "Project rules."
      assert Tools.prepend_agents_md(nil, dir) == "Project rules."
    end

    @tag :tmp_dir
    test "returns system prompt unchanged when no AGENTS.md found", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, ".git"))
      assert Tools.prepend_agents_md("You implement.", dir) == "You implement."
    end

    @tag :tmp_dir
    test "walks up to find AGENTS.md", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, ".git"))
      subdir = Path.join(dir, "src/lib")
      File.mkdir_p!(subdir)
      File.write!(Path.join(dir, "AGENTS.md"), "Root rules.")
      assert Tools.prepend_agents_md("prompt", subdir) == "Root rules.\n\nprompt"
    end

    @tag :tmp_dir
    test "stops at .git boundary and does not load AGENTS.md above it", %{tmp_dir: dir} do
      project = Path.join(dir, "project")
      File.mkdir_p!(Path.join(project, ".git"))
      File.write!(Path.join(dir, "AGENTS.md"), "Should not be loaded.")
      assert Tools.prepend_agents_md("prompt", project) == "prompt"
    end

    test "returns empty string when both cwd is empty and system prompt is nil" do
      assert Tools.prepend_agents_md(nil, "") == ""
    end
  end
end
