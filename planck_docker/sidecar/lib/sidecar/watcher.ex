defmodule Sidecar.Watcher do
  @moduledoc """
  Watches the workspace directory and keeps the Typesense index in sync.

  On start: performs a full index of all existing files, then switches to
  watch mode. Retries the Typesense connection with backoff on startup.
  """

  use GenServer

  require Logger

  @retry_delay 2_000

  @excluded_dirs ~w(.planck/sessions .planck/sidecar .git node_modules _build deps)

  @typedoc "Document"
  @type doc :: %{
          :id => String.t(),
          :path => Path.t(),
          :content => String.t(),
          :updated_at => integer()
        }

  @doc "Starts the workspace watcher under its supervisor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ [])

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ---------------------------------------------------------------------------

  @impl true
  def init(opts)

  def init(_opts) do
    workspace = Sidecar.Config.workspace_dir!()
    {:ok, %{workspace: workspace, watcher: nil}, {:continue, :init_index}}
  end

  @impl true
  def handle_continue(event, state)

  def handle_continue(:init_index, state) do
    if typesense_ready?() do
      ensure_collection()
      index_all(state.workspace)
      {:ok, watcher} = FileSystem.start_link(dirs: [state.workspace])
      FileSystem.subscribe(watcher)
      Logger.info("[Sidecar.Watcher] watching #{state.workspace}")
      {:noreply, %{state | watcher: watcher}}
    else
      Logger.debug("[Sidecar.Watcher] Typesense not ready — retrying in #{@retry_delay}ms")
      Process.send_after(self(), :retry_init, @retry_delay)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(event, state)

  def handle_info(:retry_init, state) do
    {:noreply, state, {:continue, :init_index}}
  end

  def handle_info({:file_event, _watcher, {path, events}}, state) do
    path = to_string(path)

    cond do
      excluded?(path, state.workspace) ->
        :ok

      :removed in events or :deleted in events ->
        delete_document(path)

      :created in events or :modified in events ->
        index_file(path, state.workspace)

      true ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Indexing

  @doc "Indexes every eligible file under `workspace` in Typesense."
  @spec index_all(Path.t()) :: :ok
  def index_all(workspace) do
    Logger.info("[Sidecar.Watcher] starting full index of #{workspace}")

    workspace
    |> File.ls!()
    |> Enum.flat_map(&list_files(Path.join(workspace, &1), workspace))
    |> Enum.each(&index_file(&1, workspace))

    Logger.info("[Sidecar.Watcher] full index complete")
  end

  @doc "Upserts a single file into the Typesense index, skipping excluded paths and files with no extractable content."
  @spec index_file(Path.t(), Path.t()) :: :ok
  def index_file(path, workspace) do
    with false <- excluded?(path, workspace),
         {:ok, content} <- extract_content(path) do
      relative = Path.relative_to(path, workspace)

      doc = %{
        id: Base.encode16(:crypto.hash(:sha256, path), case: :lower),
        path: relative,
        content: content,
        updated_at: System.system_time(:second)
      }

      upsert_document(doc)
    else
      _ -> :ok
    end
  end

  @spec extract_content(Path.t()) ::
          {:ok, String.t()}
          | :error
  defp extract_content(path)

  defp extract_content(path) when is_binary(path) do
    if Sidecar.FileType.binary?(path) do
      extract_via_tika(path)
    else
      extract_text(path)
    end
  end

  @spec extract_via_tika(Path.t()) :: {:ok, String.t()} | :error
  defp extract_via_tika(path)

  defp extract_via_tika(path) when is_binary(path) do
    tika_url = Sidecar.Config.tika_url!()

    options = [
      headers: [
        {"Accept", "text/plain"},
        {"Content-Type", "application/octet-stream"}
      ]
    ]

    with {:ok, bytes} <- File.read(path),
         options = Keyword.put(options, :body, bytes),
         {:ok, %{status: 200, body: text}} <- Req.post("#{tika_url}/tika", options),
         true <- is_binary(text) and text != "" do
      {:ok, text}
    else
      _ -> :error
    end
  end

  @spec extract_text(Path.t()) :: {:ok, String.t()} | :error
  defp extract_text(path)

  defp extract_text(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      _ -> :error
    end
  end

  # ---------------------------------------------------------------------------
  # Typesense HTTP

  @spec typesense_ready?() :: boolean()
  defp typesense_ready? do
    options = [headers: typesense_headers()]

    case Req.get(typesense_url("/health"), options) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  end

  @spec ensure_collection() :: :ok
  defp ensure_collection do
    schema = %{
      name: Sidecar.Config.typesense_collection!(),
      fields: [
        %{name: "path", type: "string"},
        %{name: "content", type: "string"},
        %{name: "updated_at", type: "int64"}
      ]
    }

    options = [headers: typesense_headers(), json: schema]

    case Req.post(typesense_url("/collections"), options) do
      {:ok, %{status: status}} when status in [201, 409] ->
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[Sidecar.Watcher] collection: #{status} #{inspect(body)}")

      {:error, reason} ->
        Logger.error("[Sidecar.Watcher] collection error: #{inspect(reason)}")
    end
  end

  @spec upsert_document(map()) :: :ok
  defp upsert_document(doc)

  defp upsert_document(doc) when is_map(doc) do
    collection = Sidecar.Config.typesense_collection!()
    url = typesense_url("/collections/#{collection}/documents?action=upsert")
    options = [headers: typesense_headers(), json: doc]

    case Req.post(url, options) do
      {:ok, %{status: status}} when status in [200, 201] ->
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[Sidecar.Watcher] upsert #{doc.path}: #{status} #{inspect(body)}")

      {:error, reason} ->
        Logger.error("[Sidecar.Watcher] upsert error: #{inspect(reason)}")
    end
  end

  @spec delete_document(Path.t()) :: :ok
  defp delete_document(path)

  defp delete_document(path) when is_binary(path) do
    collection = Sidecar.Config.typesense_collection!()
    id = Base.encode16(:crypto.hash(:sha256, path), case: :lower)
    url = typesense_url("/collections/#{collection}/documents/#{id}")
    options = [headers: typesense_headers()]

    case Req.delete(url, options) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("[Sidecar.Watcher] delete error: #{inspect(reason)}")
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers

  @spec typesense_url(String.t()) :: String.t()
  defp typesense_url(path)

  defp typesense_url(path) when is_binary(path) do
    base = Sidecar.Config.typesense_url!()
    base <> path
  end

  @spec typesense_headers() :: [{String.t(), String.t()}]
  defp typesense_headers do
    key = Sidecar.Config.typesense_api_key!()
    [{"X-TYPESENSE-API-KEY", key}]
  end

  @spec excluded?(Path.t(), Path.t()) :: boolean()
  defp excluded?(path, workspace)

  defp excluded?(path, workspace)
       when is_binary(path) and is_binary(workspace) do
    relative = Path.relative_to(path, workspace)
    Enum.any?(@excluded_dirs, &String.starts_with?(relative, &1))
  end

  @spec list_files(Path.t(), Path.t()) :: [Path.t()]
  defp list_files(path, workspace)

  defp list_files(path, workspace)
       when is_binary(path) and is_binary(workspace) do
    if excluded?(path, workspace) do
      []
    else
      do_list_files(path, workspace)
    end
  end

  @spec do_list_files(Path.t(), Path.t()) :: [Path.t()]
  defp do_list_files(path, workspace)

  defp do_list_files(path, workspace)
       when is_binary(path) and is_binary(workspace) do
    with true <- File.dir?(path),
         {:ok, entries} <- File.ls(path) do
      Enum.flat_map(entries, &list_files(Path.join(path, &1), workspace))
    else
      false -> [path]
      _ -> []
    end
  end
end
