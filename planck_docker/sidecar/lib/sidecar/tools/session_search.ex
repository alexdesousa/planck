defmodule Sidecar.Tools.SessionSearch do
  @moduledoc "Queries the Typesense sessions collection for past turn content."

  @doc "Returns the `session_search` tool definition."
  @spec tool() :: Planck.Agent.Tool.t()
  def tool do
    Planck.Agent.Tool.new(
      name: "session_search",
      description:
        "Search past sessions for relevant context. Use when the user references " <>
          "something that may have been discussed in a previous session, or when you " <>
          "need to recall prior work, decisions, or context not present in the current conversation.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "What to search for"},
          "agent_name" => %{
            "type" => "string",
            "description" =>
              "Filter results to a specific agent (e.g. \"orchestrator\"). Omit to search across all agents."
          }
        },
        "required" => ["query"]
      },
      execute_fn: fn _agent_id, _id, args ->
        search(args["query"], args["agent_name"])
      end
    )
  end

  @doc "Searches the sessions collection. `agent_name` is optional."
  @spec search(String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def search(query, agent_name \\ nil)

  def search(query, agent_name) when is_binary(query) do
    collection = Sidecar.Config.sessions_collection!()

    params =
      %{q: query, query_by: "content", per_page: 10, sort_by: "_text_match:desc,timestamp:desc"}
      |> maybe_add_filter(agent_name)

    case Sidecar.Typesense.search(collection, params) do
      {:ok, body} -> {:ok, format_results(body)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------

  @spec maybe_add_filter(map(), String.t() | nil) :: map()
  defp maybe_add_filter(params, nil), do: params

  defp maybe_add_filter(params, agent_name),
    do: Map.put(params, :filter_by, "agent_name:=#{agent_name}")

  @spec format_results(map()) :: String.t()
  defp format_results(%{"hits" => [_ | _] = hits}) do
    Enum.map_join(hits, "\n\n---\n\n", fn %{"document" => doc} ->
      role = doc["role"] || "unknown"
      content = String.slice(doc["content"] || "", 0, 500)
      agent = doc["agent_name"] || "unknown"
      "**[#{agent} / #{role}]** #{content}"
    end)
  end

  defp format_results(_), do: "No results found."
end
