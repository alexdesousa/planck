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
    collection = Sidecar.Config.typesense_collection!()
    params = %{q: query, query_by: "content,path", per_page: 10}

    case Sidecar.Typesense.search(collection, params) do
      {:ok, body} -> {:ok, format_results(body)}
      {:error, reason} -> {:error, reason}
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
