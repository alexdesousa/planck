defmodule Sidecar.Tools.SearchWorkspace do
  @moduledoc "Queries Typesense for files in the workspace."

  @doc "Returns the `search_workspace` tool definition."
  @spec tool() :: Planck.Agent.Tool.t()
  def tool do
    Planck.Agent.Tool.new(
      name: "search_workspace",
      description:
        "Use when you need to find files or content in the workspace. " <>
          "Returns ranked results from the indexed workspace files.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "Search query"}
        },
        "required" => ["query"]
      },
      execute_fn: fn _agent_id, _id, %{"query" => query} ->
        search(query)
      end
    )
  end

  @doc "Searches the Typesense workspace index for `query` and returns formatted results."
  @spec search(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def search(query)

  def search(query) when is_binary(query) do
    base_url = Sidecar.Config.typesense_url!()
    api_key = Sidecar.Config.typesense_api_key!()
    collection = Sidecar.Config.typesense_collection!()
    params = URI.encode_query(%{q: query, query_by: "content,path", per_page: 10})
    url = "#{base_url}/collections/#{collection}/documents/search?#{params}"

    case Req.get(url, headers: [{"X-TYPESENSE-API-KEY", api_key}]) do
      {:ok, %{status: 200, body: body}} -> {:ok, format_results(body)}
      {:ok, %{status: status}} -> {:error, "Typesense returned #{status}"}
      {:error, reason} -> {:error, "search_workspace failed: #{inspect(reason)}"}
    end
  end

  @spec format_results(map()) :: String.t()
  defp format_results(hits)

  defp format_results(%{"hits" => [_ | _] = hits}) do
    Enum.map_join(hits, "\n\n", fn %{"document" => doc} ->
      "**#{doc["path"]}**\n#{String.slice(doc["content"] || "", 0, 300)}"
    end)
  end

  defp format_results(_) do
    "No results found."
  end
end
