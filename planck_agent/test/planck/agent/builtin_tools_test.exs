defmodule Planck.Agent.BuiltinToolsTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Planck.Agent.BuiltinTools

  defp call(tool, args), do: tool.execute_fn.("test-id", args)

  # --- read ---

  describe "read/0" do
    test "reads an existing file", %{tmp_dir: dir} do
      path = Path.join(dir, "hello.txt")
      File.write!(path, "hello world")

      assert {:ok, "hello world"} = call(BuiltinTools.read(), %{"path" => path})
    end

    test "returns error for a missing file" do
      assert {:error, reason} = call(BuiltinTools.read(), %{"path" => "/no/such/file.txt"})
      assert reason =~ "cannot read"
    end

    test "expands ~ in paths" do
      filename = "planck_test_#{System.unique_integer([:positive])}.txt"
      real_path = Path.join(System.user_home!(), filename)
      tilde_path = "~/#{filename}"

      File.write!(real_path, "tilde content")

      try do
        assert {:ok, "tilde content"} = call(BuiltinTools.read(), %{"path" => tilde_path})
      after
        File.rm(real_path)
      end
    end

    test "skips lines with offset", %{tmp_dir: dir} do
      path = Path.join(dir, "lines.txt")
      File.write!(path, "a\nb\nc\nd\n")

      assert {:ok, content} = call(BuiltinTools.read(), %{"path" => path, "offset" => 2})
      assert content == "c\nd\n"
    end

    test "limits lines returned", %{tmp_dir: dir} do
      path = Path.join(dir, "lines.txt")
      File.write!(path, "a\nb\nc\nd\n")

      assert {:ok, content} = call(BuiltinTools.read(), %{"path" => path, "limit" => 2})
      assert content == "a\nb\n"
    end

    test "combines offset and limit", %{tmp_dir: dir} do
      path = Path.join(dir, "lines.txt")
      File.write!(path, "a\nb\nc\nd\ne\n")

      assert {:ok, content} =
               call(BuiltinTools.read(), %{"path" => path, "offset" => 1, "limit" => 2})

      assert content == "b\nc\n"
    end

    test "returns empty string when offset exceeds file length", %{tmp_dir: dir} do
      path = Path.join(dir, "short.txt")
      File.write!(path, "one\ntwo\n")

      assert {:ok, ""} = call(BuiltinTools.read(), %{"path" => path, "offset" => 10})
    end
  end

  # --- write ---

  describe "write/0" do
    test "writes content to a new file", %{tmp_dir: dir} do
      path = Path.join(dir, "out.txt")
      assert {:ok, _} = call(BuiltinTools.write(), %{"path" => path, "content" => "data"})
      assert File.read!(path) == "data"
    end

    test "overwrites existing file content", %{tmp_dir: dir} do
      path = Path.join(dir, "out.txt")
      File.write!(path, "old")
      assert {:ok, _} = call(BuiltinTools.write(), %{"path" => path, "content" => "new"})
      assert File.read!(path) == "new"
    end

    test "creates missing parent directories", %{tmp_dir: dir} do
      path = Path.join([dir, "a", "b", "c.txt"])
      assert {:ok, _} = call(BuiltinTools.write(), %{"path" => path, "content" => "nested"})
      assert File.read!(path) == "nested"
    end

    test "returns error when a path component is a file", %{tmp_dir: dir} do
      blocker = Path.join(dir, "blocker")
      File.write!(blocker, "I am a file")
      path = Path.join(blocker, "out.txt")

      assert {:error, reason} = call(BuiltinTools.write(), %{"path" => path, "content" => "x"})
      assert reason =~ "cannot write"
    end
  end

  # --- edit ---

  describe "edit/0" do
    test "replaces a unique string in a file", %{tmp_dir: dir} do
      path = Path.join(dir, "code.ex")
      File.write!(path, "def hello, do: :world\n")

      assert {:ok, _} =
               call(BuiltinTools.edit(), %{
                 "path" => path,
                 "old_string" => ":world",
                 "new_string" => ":earth"
               })

      assert File.read!(path) == "def hello, do: :earth\n"
    end

    test "returns error when old_string is not found", %{tmp_dir: dir} do
      path = Path.join(dir, "file.txt")
      File.write!(path, "some content")

      assert {:error, reason} =
               call(BuiltinTools.edit(), %{
                 "path" => path,
                 "old_string" => "not here",
                 "new_string" => "replacement"
               })

      assert reason =~ "not found"
    end

    test "returns error when old_string appears more than once", %{tmp_dir: dir} do
      path = Path.join(dir, "dup.txt")
      File.write!(path, "foo bar foo")

      assert {:error, reason} =
               call(BuiltinTools.edit(), %{
                 "path" => path,
                 "old_string" => "foo",
                 "new_string" => "baz"
               })

      assert reason =~ "more than once"
    end

    test "returns error for a missing file" do
      assert {:error, reason} =
               call(BuiltinTools.edit(), %{
                 "path" => "/no/such/file.txt",
                 "old_string" => "x",
                 "new_string" => "y"
               })

      assert reason =~ "cannot access"
    end
  end

  # --- bash ---

  describe "bash/0" do
    test "runs a command and returns its stdout" do
      bash = BuiltinTools.bash()
      assert {:ok, output} = call(bash, %{"command" => "echo hello"})
      assert String.trim(output) == "hello"
    end

    test "captures stderr alongside stdout" do
      bash = BuiltinTools.bash()
      assert {:ok, output} = call(bash, %{"command" => "echo out && echo err >&2"})
      assert output =~ "out"
      assert output =~ "err"
    end

    test "returns error for non-zero exit" do
      bash = BuiltinTools.bash()
      assert {:error, reason} = call(bash, %{"command" => "exit 42"})
      assert reason =~ "42"
    end

    test "runs command from the specified cwd", %{tmp_dir: dir} do
      bash = BuiltinTools.bash()
      assert {:ok, output} = call(bash, %{"command" => "pwd", "cwd" => dir})
      # resolve both to handle symlinks (e.g. /private/var on macOS)
      assert Path.expand(String.trim(output)) == Path.expand(dir)
    end

    test "returns error when command times out" do
      bash = BuiltinTools.bash()
      assert {:error, reason} = call(bash, %{"command" => "sleep 60", "timeout" => 100})
      assert reason =~ "timed out"
    end
  end
end
