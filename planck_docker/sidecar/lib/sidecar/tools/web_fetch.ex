defmodule Sidecar.Tools.WebFetch do
  @moduledoc """
  Fetches a URL and returns clean markdown via @mozilla/readability + turndown.

  Results are cached to `web_cache/` in the workspace and indexed by Typesense
  automatically, building a local mirror of fetched pages over time. Use
  `search_workspace` to find content across all cached pages without re-fetching.
  """

  @timeout 15_000

  # erlexec return types are imprecise in dialyzer; suppress false positives.
  @dialyzer {:nowarn_function, fetch: 2, tool: 0}

  @doc "Returns the `web_fetch` tool definition."
  @spec tool() :: Planck.Agent.Tool.t()
  def tool do
    Planck.Agent.Tool.new(
      name: "web_fetch",
      description:
        "Use when you need to read the content of a web page. " <>
          "Fetches the URL, strips noise, and returns clean markdown. " <>
          "Results are cached to the workspace and indexed for search. " <>
          "Use offset/limit to paginate long pages.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "url" => %{"type" => "string", "description" => "URL to fetch"},
          "refresh" => %{
            "type" => "boolean",
            "description" => "Re-fetch even if cached (default: false)"
          },
          "offset" => %{
            "type" => "integer",
            "description" => "Line offset into the content (default: 0)"
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of lines to return"
          }
        },
        "required" => ["url"]
      },
      execute_fn: fn _agent_id, _id, args ->
        fetch(args["url"],
          refresh: Map.get(args, "refresh", false),
          offset: Map.get(args, "offset", 0),
          limit: Map.get(args, "limit")
        )
      end
    )
  end

  @doc "Fetches `url` and returns clean markdown, using the disk cache when available."
  @spec fetch(String.t(), keyword()) ::
          {:ok, String.t()}
          | {:error, String.t()}
  def fetch(url, opts \\ [])

  def fetch(url, opts)
      when is_binary(url) and is_list(opts) do
    refresh = Keyword.get(opts, :refresh, false)
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit)
    path = cache_path(url)

    with {:ok, markdown} <- maybe_fetch(url, path, refresh) do
      {:ok, slice(markdown, offset, limit)}
    end
  end

  # ---------------------------------------------------------------------------
  # Private

  @spec maybe_fetch(String.t(), Path.t(), boolean()) ::
          {:ok, String.t()}
          | {:error, String.t()}
  defp maybe_fetch(url, path, refresh)

  defp maybe_fetch(url, path, refresh)
       when is_binary(url) and is_binary(path) and is_boolean(refresh) do
    with true <- not refresh,
         true <- File.exists?(path),
         {:ok, content} <- File.read(path) do
      {:ok, content}
    else
      _ ->
        do_fetch(url, path)
    end
  end

  @spec do_fetch(String.t(), Path.t()) ::
          {:ok, String.t()}
          | {:error, String.t()}
  defp do_fetch(url, cache_path)
       when is_binary(url) and is_binary(cache_path) do
    script = Path.expand("assets/readability.js", File.cwd!())
    cmd = Enum.map([node_bin(), script, url], &String.to_charlist/1)
    task = Task.async(fn -> :exec.run(cmd, [:sync, :stdout, :stderr]) end)

    case Task.yield(task, @timeout) || Task.shutdown(task) do
      {:ok, {:ok, [stdout: output]}} ->
        markdown = IO.iodata_to_binary(output)
        write_cache(cache_path, url, markdown)
        {:ok, markdown}

      {:ok, {:ok, [stdout: output, stderr: _]}} ->
        markdown = IO.iodata_to_binary(output)
        write_cache(cache_path, url, markdown)
        {:ok, markdown}

      {:ok, {:ok, []}} ->
        {:error, "web_fetch returned empty output"}

      {:ok, {:error, [stderr: err]}} ->
        {:error, "web_fetch failed: #{IO.iodata_to_binary(err)}"}

      {:ok, {:error, reason}} ->
        {:error, "web_fetch failed: #{inspect(reason)}"}

      nil ->
        {:error, "web_fetch timed out after #{@timeout}ms"}
    end
  end

  @spec node_bin() :: String.t() | nil
  defp node_bin, do: System.find_executable("node") || System.find_executable("nodejs")

  @spec write_cache(Path.t(), String.t(), String.t()) :: :ok
  defp write_cache(path, url, markdown)

  defp write_cache(path, url, markdown)
       when is_binary(path) and is_binary(url) and is_binary(markdown) do
    File.mkdir_p!(Path.dirname(path))
    cached_at = DateTime.utc_now() |> DateTime.to_iso8601()

    content = """
    <!-- planck:url #{url} -->
    <!-- planck:cached_at #{cached_at} -->

    #{markdown}
    """

    File.write!(path, content)
  end

  @spec cache_path(String.t()) :: Path.t()
  defp cache_path(url)

  defp cache_path(url) when is_binary(url) do
    workspace = Sidecar.Config.workspace_dir!()
    hash = :crypto.hash(:sha256, url) |> Base.encode16(case: :lower)
    Path.join([workspace, "web_cache", "#{hash}.md"])
  end

  @spec slice(String.t(), non_neg_integer(), pos_integer() | nil) :: String.t()
  defp slice(content, offset, limit)

  defp slice(content, 0, nil) when is_binary(content) do
    content
  end

  defp slice(content, offset, nil)
       when is_binary(content) and is_integer(offset) and offset > 0 do
    content
    |> String.split("\n")
    |> Enum.drop(offset)
    |> Enum.join("\n")
  end

  defp slice(content, offset, limit)
       when is_binary(content) and is_integer(offset) and is_integer(limit) and
              offset >= 0 and limit >= 1 do
    content
    |> String.split("\n")
    |> Enum.drop(offset)
    |> Enum.take(limit)
    |> Enum.join("\n")
  end
end
