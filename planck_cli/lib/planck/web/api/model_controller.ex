defmodule Planck.Web.API.ModelController do
  use Planck.Web, :controller

  alias OpenApiSpex.Operation
  alias Planck.Web.API.Schemas

  def open_api_operation(:index),
    do: %Operation{
      tags: ["Resources"],
      summary: "List models",
      description: "Returns all configured and available models.",
      operationId: "ModelController.index",
      responses: %{200 => Operation.response("Models", "application/json", Schemas.ModelList)}
    }

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    models =
      Headless.available_models()
      |> Enum.map(fn m ->
        %{provider: m.provider, id: m.id, context_window: m.context_window, base_url: m.base_url}
      end)

    json(conn, models)
  end
end
