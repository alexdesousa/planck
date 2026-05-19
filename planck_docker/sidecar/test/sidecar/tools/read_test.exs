defmodule Sidecar.Tools.ReadTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Sidecar.{Config, Tools.Read}

  setup %{tmp_dir: dir} do
    Application.put_env(:sidecar, :workspace_dir, dir)
    Config.reload_workspace_dir()

    on_exit(fn ->
      Application.delete_env(:sidecar, :workspace_dir)
      Config.reload_workspace_dir()
    end)

    {:ok, workspace: dir}
  end

  # ---------------------------------------------------------------------------
  # Text files — identical to built-in read behaviour

  test "reads a plain text file", %{workspace: workspace} do
    File.write!(Path.join(workspace, "notes.md"), "# Hello\n\nWorld.")
    assert {:ok, "# Hello\n\nWorld."} = Read.read("notes.md")
  end

  test "applies offset to text files", %{workspace: workspace} do
    File.write!(Path.join(workspace, "file.txt"), "a\nb\nc\nd")
    assert {:ok, content} = Read.read("file.txt", offset: 2)
    assert content == "c\nd"
  end

  test "applies limit to text files", %{workspace: workspace} do
    File.write!(Path.join(workspace, "file.txt"), "a\nb\nc\nd")
    assert {:ok, content} = Read.read("file.txt", limit: 2)
    assert content == "a\nb"
  end

  test "returns error for missing file", %{workspace: _workspace} do
    assert {:error, _reason} = Read.read("nonexistent.md")
  end

  test "rejects paths outside the workspace", %{workspace: _workspace} do
    assert {:error, msg} = Read.read("../../etc/passwd")
    assert msg =~ "Access denied"
  end

  # ---------------------------------------------------------------------------
  # Binary files — Tika extraction

  test "prepends format header for binary files and caches result", %{workspace: workspace} do
    bypass = Bypass.open()
    Application.put_env(:sidecar, :tika_url, "http://localhost:#{bypass.port}")
    Config.reload_tika_url()

    File.write!(Path.join(workspace, "report.pdf"), <<0x25, 0x50, 0x44, 0x46, 0xFF, 0xFE>>)

    Bypass.expect_once(bypass, "PUT", "/tika", fn conn ->
      Plug.Conn.resp(conn, 200, "Extracted PDF content.")
    end)

    assert {:ok, content} = Read.read("report.pdf")
    assert content =~ "[Format: pdf"
    assert content =~ "cannot be edited"
    assert content =~ "Extracted PDF content."

    # Cache was written
    assert File.ls!(Path.join(workspace, "doc_cache")) |> length() == 1

    Application.delete_env(:sidecar, :tika_url)
    Config.reload_tika_url()
  end

  test "returns cached extraction without calling Tika again", %{workspace: workspace} do
    bypass = Bypass.open()
    Application.put_env(:sidecar, :tika_url, "http://localhost:#{bypass.port}")
    Config.reload_tika_url()

    path = Path.join(workspace, "doc.docx")
    File.write!(path, <<0x50, 0x4B, 0x03, 0x04, 0xFF, 0xFE>>)

    Bypass.expect_once(bypass, "PUT", "/tika", fn conn ->
      Plug.Conn.resp(conn, 200, "Extracted text.")
    end)

    # First call — Tika is invoked
    assert {:ok, _} = Read.read("doc.docx")

    # Second call — cache is used, Bypass would fail if Tika is called again
    Bypass.stub(bypass, "PUT", "/tika", fn _conn ->
      flunk("Tika should not be called again — result is cached")
    end)

    assert {:ok, content} = Read.read("doc.docx")
    assert content =~ "Extracted text."

    Application.delete_env(:sidecar, :tika_url)
    Config.reload_tika_url()
  end

  test "re-extracts when source file changes", %{workspace: workspace} do
    bypass = Bypass.open()
    Application.put_env(:sidecar, :tika_url, "http://localhost:#{bypass.port}")
    Config.reload_tika_url()

    path = Path.join(workspace, "sheet.xlsx")
    File.write!(path, <<0x25, 0x50, 0x44, 0x46, 0xFF, 0xFE>>)

    Bypass.stub(bypass, "PUT", "/tika", fn conn ->
      Plug.Conn.resp(conn, 200, "New content.")
    end)

    # Prime the cache
    assert {:ok, _} = Read.read("sheet.xlsx")

    # Simulate file update — write new content and touch mtime
    Process.sleep(10)
    File.write!(path, <<0x25, 0x50, 0x44, 0x46, 0xFF, 0xFE>>)

    assert {:ok, content} = Read.read("sheet.xlsx")
    assert content =~ "New content."

    Application.delete_env(:sidecar, :tika_url)
    Config.reload_tika_url()
  end

  test "returns error when Tika is unavailable", %{workspace: workspace} do
    Application.put_env(:sidecar, :tika_url, "http://localhost:1")
    Config.reload_tika_url()

    File.write!(Path.join(workspace, "file.pdf"), <<0x25, 0x50, 0x44, 0x46, 0xFF, 0xFE>>)

    assert {:error, msg} = Read.read("file.pdf")
    assert msg =~ "Tika unavailable"

    Application.delete_env(:sidecar, :tika_url)
    Config.reload_tika_url()
  end
end
