defmodule Planck.Web.API.TeamController do
  use Planck.Web, :controller

  alias OpenApiSpex.Operation
  alias Planck.Web.API.Schemas

  def open_api_operation(:index),
    do: %Operation{
      tags: ["Resources"],
      summary: "List teams",
      description: "Returns all registered team aliases with name and description.",
      operationId: "TeamController.index",
      responses: %{200 => Operation.response("Teams", "application/json", Schemas.TeamList)}
    }

  def open_api_operation(:show),
    do: %Operation{
      tags: ["Resources"],
      summary: "Get a team",
      operationId: "TeamController.show",
      parameters: [
        Operation.parameter(:alias, :path, :string, "Team alias", required: true)
      ],
      responses: %{
        200 => Operation.response("Team", "application/json", Schemas.TeamDetail),
        404 => Operation.response("Error", "application/json", Schemas.Error)
      }
    }

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    json(conn, Headless.list_teams())
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"alias" => team_alias}) do
    case Headless.get_team(team_alias) do
      {:ok, team} ->
        members =
          Enum.map(team.members, fn spec ->
            %{type: spec.type, name: spec.name, model_id: spec.model_id}
          end)

        json(conn, %{alias: team_alias, name: team.name, members: members})

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "Team not found"})
    end
  end
end
