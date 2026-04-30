defmodule Planck.Web.ConnCase do
  @moduledoc """
  Test case for controllers and LiveViews requiring a connection.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint Planck.Web.Endpoint

      use Planck.Web, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import OpenApiSpex.TestAssertions
      import Planck.Web.ConnCase
    end
  end

  @doc "Returns the cached OpenAPI spec for use with `assert_schema/3`."
  @spec api_spec() :: OpenApiSpex.OpenApi.t()
  def api_spec, do: Planck.Web.API.Spec.spec()

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
