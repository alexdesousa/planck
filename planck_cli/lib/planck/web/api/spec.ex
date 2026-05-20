defmodule Planck.Web.API.Spec do
  @moduledoc "OpenAPI specification for the Planck HTTP API."

  alias OpenApiSpex.{Info, OpenApi, Paths, Server}
  alias Planck.Web.Router

  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      servers: [%Server{url: "/"}],
      info: %Info{
        title: "Planck API",
        version: to_string(Application.spec(:planck_cli, :vsn)),
        description: "HTTP API for managing Planck multi-agent sessions."
      },
      paths: Paths.from_router(Router)
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
