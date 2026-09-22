defmodule Planck.Headless.WidgetsTest do
  use ExUnit.Case, async: false

  alias Planck.Headless.Widgets

  # No sidecar is configured/connected in the plain unit test environment —
  # SidecarManager.node/0 genuinely returns nil here (see
  # sidecar_manager_test.exs's "node/0 returns nil when no sidecar is
  # connected"), so the fallback branch is exercised for real, not mocked.
  # RPC success/failure against a real sidecar node is covered by
  # sidecar_integration_test.exs (run via `mix test.integration`).

  describe "list/0" do
    test "returns [] when no sidecar is connected" do
      assert Widgets.list() == []
    end
  end

  describe "render/2" do
    test "returns {:error, :sidecar_not_connected} when no sidecar is connected" do
      assert {:error, :sidecar_not_connected} = Widgets.render("counter", 42)
    end
  end

  describe "dispatch_action/3" do
    test "returns {:error, :sidecar_not_connected} when no sidecar is connected" do
      assert {:error, :sidecar_not_connected} =
               Widgets.dispatch_action("counter", "increment", %{})
    end
  end

  describe "container/1" do
    test "returns {:error, :sidecar_not_connected} when no sidecar is connected" do
      assert {:error, :sidecar_not_connected} = Widgets.container("counter")
    end
  end
end
