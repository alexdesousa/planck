defmodule Sidecar.Tools.SearchWeb do
  @moduledoc "Queries Searxng for web search results."

  @doc "Returns the `search_web` tool definition."
  @spec tool() :: Planck.Agent.Tool.t()
  def tool do
    Planck.Agent.Tool.new(
      name: "search_web",
      description:
        "Use when you need to search the web for current information. " <>
          "Returns privacy-respecting search results via a local Searxng instance.",
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

  @doc "Queries Searxng for `query` and returns formatted web results."
  @spec search(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def search(query)

  def search(query) when is_binary(query) do
    base_url = Sidecar.Config.searxng_url!()
    url = "#{base_url}/search"

    case Req.get(url, params: [q: query, format: "json"]) do
      {:ok, %{status: 200, body: body}} -> {:ok, format_results(body)}
      {:ok, %{status: status}} -> {:error, "Searxng returned #{status}"}
      {:error, reason} -> {:error, "search_web failed: #{inspect(reason)}"}
    end
  end

  @spec format_results(map()) :: String.t()
  defp format_results(results)

  defp format_results(%{"results" => [_ | _] = results}) do
    results
    |> Enum.take(5)
    |> Enum.map_join("\n\n", fn r ->
      "**#{r["title"]}**\n#{r["url"]}\n#{r["content"] || ""}"
    end)
  end

  defp format_results(_) do
    "No results found."
  end
end
