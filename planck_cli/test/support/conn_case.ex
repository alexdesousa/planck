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
      import Planck.Web.ConnCase
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
