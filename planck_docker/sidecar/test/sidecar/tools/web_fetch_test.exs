defmodule Sidecar.Tools.WebFetchTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Sidecar.{Config, Tools.WebFetch}

  setup %{tmp_dir: dir} do
    Application.put_env(:sidecar, :workspace_dir, dir)
    Config.reload_workspace_dir()

    on_exit(fn ->
      Application.delete_env(:sidecar, :workspace_dir)
      Config.reload_workspace_dir()
    end)

    {:ok, workspace: dir}
  end

  @tag :integration
  test "fetches and parses a real URL" do
    assert {:ok, content} = WebFetch.fetch("https://example.com")
    assert content =~ "Example"
  end

  @tag :integration
  test "caches result to web_cache/ on first fetch", %{workspace: workspace} do
    assert {:ok, _content} = WebFetch.fetch("https://example.com")
    cache_dir = Path.join(workspace, "web_cache")
    assert File.ls!(cache_dir) |> length() == 1
  end

  test "returns cached result without re-fetching on second call", %{workspace: workspace} do
    hash = :crypto.hash(:sha256, "https://example.com") |> Base.encode16(case: :lower)
    cache_path = Path.join([workspace, "web_cache", "#{hash}.md"])
    File.mkdir_p!(Path.dirname(cache_path))
    File.write!(cache_path, "# Cached\n\nThis is cached content.")

    assert {:ok, content} = WebFetch.fetch("https://example.com")
    assert content =~ "Cached"
  end

  @tag :integration
  test "refresh: true bypasses the cache and re-fetches", %{workspace: workspace} do
    hash = :crypto.hash(:sha256, "https://example.com") |> Base.encode16(case: :lower)
    cache_path = Path.join([workspace, "web_cache", "#{hash}.md"])
    File.mkdir_p!(Path.dirname(cache_path))
    File.write!(cache_path, "# Stale cached content")

    assert {:ok, content} = WebFetch.fetch("https://example.com", refresh: true)
    refute content =~ "Stale cached content"
  end

  test "offset skips the first N lines", %{workspace: workspace} do
    hash = :crypto.hash(:sha256, "https://example.com") |> Base.encode16(case: :lower)
    cache_path = Path.join([workspace, "web_cache", "#{hash}.md"])
    File.mkdir_p!(Path.dirname(cache_path))
    File.write!(cache_path, "line1\nline2\nline3\nline4")

    assert {:ok, content} = WebFetch.fetch("https://example.com", offset: 2)
    refute content =~ "line1"
    refute content =~ "line2"
    assert content =~ "line3"
  end

  test "limit caps the number of lines returned", %{workspace: workspace} do
    hash = :crypto.hash(:sha256, "https://example.com") |> Base.encode16(case: :lower)
    cache_path = Path.join([workspace, "web_cache", "#{hash}.md"])
    File.mkdir_p!(Path.dirname(cache_path))
    File.write!(cache_path, "line1\nline2\nline3\nline4")

    assert {:ok, content} = WebFetch.fetch("https://example.com", limit: 2)
    assert content == "line1\nline2"
  end

  @tag :integration
  test "returns error for an invalid URL" do
    assert {:error, _reason} = WebFetch.fetch("http://localhost:1/nonexistent")
  end
end
