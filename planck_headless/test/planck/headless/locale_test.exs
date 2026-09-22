defmodule Planck.Headless.LocaleTest do
  use ExUnit.Case, async: false

  alias Planck.Headless.Locale

  # No sidecar is configured/connected in the plain unit test environment —
  # SidecarManager.node/0 genuinely returns nil here (see
  # sidecar_manager_test.exs's "node/0 returns nil when no sidecar is
  # connected"), so the fallback branch is exercised for real, not mocked.
  # A real RPC round-trip is covered by sidecar_integration_test.exs (run
  # via `mix test.integration`).

  describe "set/1" do
    test "returns :ok when no sidecar is connected" do
      assert Locale.set("es") == :ok
    end
  end
end
