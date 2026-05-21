defmodule Sidecar.Typesense do
  @moduledoc """
  Thin HTTP client for the Typesense instance configured in `Sidecar.Config`.

  All functions read `typesense_url` and `typesense_api_key` from config at
  call time, so config reloads are picked up automatically.
  """

  require Logger

  @doc "Returns `true` when the Typesense health endpoint responds with 200."
  @spec ready?() :: boolean()
  def ready? do
    case Req.get(url("/health"), headers: headers()) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  end

  @doc """
  Create the collection described by `schema` if it does not already exist.
  A 409 (already exists) is treated as success.
  """
  @spec ensure_collection(map()) :: :ok
  def ensure_collection(schema) do
    case Req.post(url("/collections"), headers: headers(), json: schema) do
      {:ok, %{status: status}} when status in [201, 409] ->
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[Sidecar.Typesense] ensure_collection: #{status} #{inspect(body)}")

      {:error, reason} ->
        Logger.error("[Sidecar.Typesense] ensure_collection error: #{inspect(reason)}")
    end
  end

  @doc "Upsert `doc` into `collection`. The map must include an `\"id\"` key."
  @spec upsert(String.t(), map()) :: :ok | {:error, String.t()}
  def upsert(collection, doc) do
    case Req.post(url("/collections/#{collection}/documents?action=upsert"),
           headers: headers(),
           json: doc
         ) do
      {:ok, %{status: status}} when status in [200, 201] ->
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[Sidecar.Typesense] upsert #{collection}: #{status} #{inspect(body)}")
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        Logger.error("[Sidecar.Typesense] upsert error: #{inspect(reason)}")
        {:error, inspect(reason)}
    end
  end

  @doc "Fetch a document by `id` from `collection`."
  @spec get(String.t(), String.t()) :: {:ok, map()} | :not_found | {:error, term()}
  def get(collection, id) do
    case Req.get(url("/collections/#{collection}/documents/#{id}"),
           headers: headers()
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 404}} -> :not_found
      {:ok, %{status: status}} -> {:error, "HTTP #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Delete the document with `id` from `collection`."
  @spec delete(String.t(), String.t()) :: :ok
  def delete(collection, id) do
    case Req.delete(url("/collections/#{collection}/documents/#{id}"), headers: headers()) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("[Sidecar.Typesense] delete error: #{inspect(reason)}")
    end

    :ok
  end

  @doc """
  Search `collection` using `params`. Returns the raw Typesense response body
  on success or an error tuple.
  """
  @spec search(String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def search(collection, params) do
    query = URI.encode_query(params)

    case Req.get(url("/collections/#{collection}/documents/search?#{query}"),
           headers: headers()
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "Typesense returned #{status}"}
      {:error, reason} -> {:error, "search failed: #{inspect(reason)}"}
    end
  end

  # ---------------------------------------------------------------------------

  @spec url(String.t()) :: String.t()
  def url(path), do: Sidecar.Config.typesense_url!() <> path

  @spec headers() :: [{String.t(), String.t()}]
  def headers, do: [{"X-TYPESENSE-API-KEY", Sidecar.Config.typesense_api_key!()}]
end
