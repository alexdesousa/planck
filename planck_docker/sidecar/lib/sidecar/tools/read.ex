defmodule Sidecar.Tools.Read do
  @moduledoc """
  Shadows the built-in `read` tool with document extraction support.

  For plain text and code files the behaviour is identical to the built-in:
  reads the file directly with optional `offset` and `limit`.

  For binary formats (PDF, DOCX, XLSX, ODS, PPTX, etc.) the file is sent to
  Apache Tika for text extraction. The result is cached to
  `doc_cache/` in the workspace and automatically invalidated when the source
  file changes. A header is prepended to the output noting the original format
  and that the file cannot be edited with `edit` — only fully overwritten with
  `write`.
  """

  @doc "Returns the `read` tool definition, shadowing the built-in."
  @spec tool() :: Planck.Agent.Tool.t()
  def tool do
    Planck.Agent.Tool.new(
      name: "read",
      description:
        "Read a file from the workspace. Supports plain text, code, and binary formats " <>
          "(PDF, DOCX, XLSX, ODS, PPTX). Binary files are extracted to text via Apache Tika " <>
          "and cached. Use offset/limit to paginate large files.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "File path (relative to workspace)"},
          "offset" => %{
            "type" => "integer",
            "description" => "Line offset (default: 0)"
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of lines to return"
          }
        },
        "required" => ["path"]
      },
      execute_fn: fn _agent_id, _id, args ->
        read(args["path"],
          offset: Map.get(args, "offset", 0),
          limit: Map.get(args, "limit")
        )
      end
    )
  end

  @doc "Reads `path` from the workspace, extracting binary formats via Tika."
  @spec read(String.t(), keyword()) ::
          {:ok, String.t()}
          | {:error, String.t()}
  def read(path, opts \\ [])

  def read(path, opts) when is_binary(path) and is_list(opts) do
    workspace = Sidecar.Config.workspace_dir!()

    abs_path =
      workspace
      |> Path.join(path)
      |> Path.expand()

    if String.starts_with?(abs_path, workspace) do
      do_read(path, opts)
    else
      {:error, "Access denied: path is outside the workspace"}
    end
  end

  # ---------------------------------------------------------------------------
  # Private

  @spec do_read(String.t(), keyword()) ::
          {:ok, String.t()}
          | {:error, String.t()}
  defp do_read(path, opts)

  defp do_read(path, opts) when is_binary(path) and is_list(opts) do
    workspace = Sidecar.Config.workspace_dir!()

    abs_path =
      workspace
      |> Path.join(path)
      |> Path.expand()

    if Sidecar.FileType.binary?(abs_path) do
      ext = Path.extname(path)
      read_binary(abs_path, path, ext, opts)
    else
      read_text(abs_path, opts)
    end
  end

  @spec read_text(Path.t(), keyword()) ::
          {:ok, String.t()}
          | {:error, String.t()}
  defp read_text(abs_path, opts)

  defp read_text(abs_path, opts)
       when is_binary(abs_path) and is_list(opts) do
    case File.read(abs_path) do
      {:ok, content} -> {:ok, slice(content, opts)}
      {:error, reason} -> {:error, "Cannot read file: #{reason}"}
    end
  end

  @spec read_binary(Path.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()}
          | {:error, String.t()}
  defp read_binary(abs_path, display_path, ext, opts)

  defp read_binary(abs_path, display_path, ext, opts)
       when is_binary(abs_path) and is_binary(display_path) and is_binary(ext) and is_list(opts) do
    cache = cache_path(abs_path)

    with {:ok, text} <- maybe_extract(abs_path, cache) do
      header =
        "[Format: #{String.trim_leading(ext, ".")} — " <>
          "this file cannot be edited with `edit`. " <>
          "Use `write` to fully overwrite it. Original: #{display_path}]\n\n"

      {:ok, header <> slice(text, opts)}
    end
  end

  @spec maybe_extract(Path.t(), Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp maybe_extract(abs_path, cache)

  defp maybe_extract(abs_path, cache)
       when is_binary(abs_path) and is_binary(cache) do
    with {:ok, %{mtime: source_mtime}} <- File.stat(abs_path),
         {:ok, cached_text} <- File.read(cache),
         {:ok, %{mtime: cache_mtime}} <- File.stat(cache),
         true <- cache_mtime >= source_mtime do
      {:ok, cached_text}
    else
      _ -> extract_via_tika(abs_path, cache)
    end
  end

  @spec extract_via_tika(Path.t(), Path.t()) ::
          {:ok, String.t()}
          | {:error, String.t()}
  defp extract_via_tika(abs_path, cache)

  defp extract_via_tika(abs_path, cache)
       when is_binary(abs_path) and is_binary(cache) do
    case File.read(abs_path) do
      {:ok, bytes} ->
        do_extract_via_tika(abs_path, cache, bytes)

      {:error, reason} ->
        {:error, "Cannot read file: #{reason}"}
    end
  end

  @spec do_extract_via_tika(Path.t(), Path.t(), String.t()) ::
          {:ok, String.t()}
          | {:error, String.t()}
  defp do_extract_via_tika(abs_path, cache, bytes)

  defp do_extract_via_tika(abs_path, cache, bytes)
       when is_binary(abs_path) and is_binary(cache) and is_binary(bytes) do
    tika_url = Sidecar.Config.tika_url!()

    options = [
      body: bytes,
      headers: [{"Accept", "text/plain"}, {"Content-Type", "application/octet-stream"}]
    ]

    case Req.post("#{tika_url}/tika", options) do
      {:ok, %{status: 200, body: text}} when is_binary(text) ->
        File.mkdir_p!(Path.dirname(cache))
        File.write!(cache, text)
        {:ok, text}

      {:ok, %{status: status}} ->
        {:error, "Tika returned #{status} for #{Path.basename(abs_path)}"}

      {:error, reason} ->
        {:error, "Tika unavailable: #{inspect(reason)}"}
    end
  end

  @spec cache_path(Path.t()) :: Path.t()
  defp cache_path(abs_path)

  defp cache_path(abs_path) when is_binary(abs_path) do
    workspace = Sidecar.Config.workspace_dir!()
    hash = :crypto.hash(:sha256, abs_path) |> Base.encode16(case: :lower)
    Path.join([workspace, "doc_cache", "#{hash}.txt"])
  end

  @spec slice(String.t(), keyword()) :: String.t()
  defp slice(content, opts)

  defp slice(content, opts) when is_binary(content) and is_list(opts) do
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit)

    case {offset, limit} do
      {0, nil} ->
        content

      {offset, nil} ->
        content
        |> String.split("\n")
        |> Enum.drop(offset)
        |> Enum.join("\n")

      {offset, limit} ->
        content
        |> String.split("\n")
        |> Enum.drop(offset)
        |> Enum.take(limit)
        |> Enum.join("\n")
    end
  end
end
