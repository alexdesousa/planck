defmodule Sidecar.WatcherTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Sidecar.{Config, Watcher}

  setup %{tmp_dir: dir} do
    bypass = Bypass.open()
    Application.put_env(:sidecar, :typesense_url, "http://localhost:#{bypass.port}")
    Application.put_env(:sidecar, :typesense_api_key, "test-key")
    Application.put_env(:sidecar, :workspace_dir, dir)
    Config.reload_typesense_url()
    Config.reload_typesense_api_key()
    Config.reload_workspace_dir()

    on_exit(fn ->
      Application.delete_env(:sidecar, :typesense_url)
      Application.delete_env(:sidecar, :typesense_api_key)
      Application.delete_env(:sidecar, :workspace_dir)
      Config.reload_typesense_url()
      Config.reload_typesense_api_key()
      Config.reload_workspace_dir()
    end)

    {:ok, bypass: bypass, workspace: dir}
  end

  test "index_file sends an upsert to Typesense", %{bypass: bypass, workspace: workspace} do
    path = Path.join(workspace, "notes.md")
    File.write!(path, "# Hello\n\nThis is a test note.")

    Bypass.expect_once(bypass, "POST", "/collections/workspace/documents", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      doc = Jason.decode!(body)
      assert doc["path"] == "notes.md"
      assert doc["content"] =~ "Hello"
      Plug.Conn.resp(conn, 201, Jason.encode!(%{id: doc["id"]}))
    end)

    Watcher.index_file(path, workspace)
  end

  test "index_file skips binary files that Tika cannot extract", %{
    bypass: bypass,
    workspace: workspace
  } do
    tika_bypass = Bypass.open()
    Application.put_env(:sidecar, :tika_url, "http://localhost:#{tika_bypass.port}")
    Config.reload_tika_url()

    path = Path.join(workspace, "image.png")
    # Real binary bytes (PNG header) — not valid UTF-8
    File.write!(path, <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>)

    # Tika returns empty — nothing to index
    Bypass.expect_once(tika_bypass, "POST", "/tika", fn conn ->
      Plug.Conn.resp(conn, 200, "")
    end)

    Bypass.stub(bypass, "POST", "/collections/workspace/documents", fn conn ->
      flunk("should not index file with no extractable content")
      conn
    end)

    Watcher.index_file(path, workspace)

    Application.delete_env(:sidecar, :tika_url)
    Config.reload_tika_url()
  end

  test "index_file skips excluded directories", %{bypass: bypass, workspace: workspace} do
    sessions_dir = Path.join(workspace, ".planck/sessions")
    File.mkdir_p!(sessions_dir)
    path = Path.join(sessions_dir, "session.db")
    File.write!(path, "data")

    Bypass.stub(bypass, "POST", "/collections/workspace/documents", fn conn ->
      flunk("should not index files in .planck/sessions")
      conn
    end)

    Watcher.index_file(path, workspace)
  end

  test "index_all indexes only eligible files", %{bypass: bypass, workspace: workspace} do
    File.write!(Path.join(workspace, "readme.md"), "# Readme")
    File.write!(Path.join(workspace, "script.sh"), "#!/bin/bash")

    File.mkdir_p!(Path.join(workspace, ".planck/sessions"))
    File.write!(Path.join(workspace, ".planck/sessions/s.db"), "db")

    upsert_count = :counters.new(1, [])

    Bypass.stub(bypass, "POST", "/collections/workspace/documents", fn conn ->
      {:ok, _, conn} = Plug.Conn.read_body(conn)
      :counters.add(upsert_count, 1, 1)
      Plug.Conn.resp(conn, 201, "{}")
    end)

    Watcher.index_all(workspace)

    # readme.md and script.sh are both valid UTF-8 text — both indexed.
    # .planck/sessions/s.db is excluded.
    assert :counters.get(upsert_count, 1) == 2
  end
end
