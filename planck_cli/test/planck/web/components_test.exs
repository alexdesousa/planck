defmodule Planck.Web.ComponentsTest do
  use ExUnit.Case, async: true

  alias Planck.Web.Components

  describe "format_context/2" do
    test "shows tokens used, the window size, and the percentage" do
      assert Components.format_context(10_000, 200_000) == "ctx 10k / 200k (5%)"
    end

    test "drops the decimal only when the rounded value is a whole number" do
      assert Components.format_context(1_200, 10_000) == "ctx 1.2k / 10k (12%)"
    end

    test "returns empty string when tokens is nil" do
      assert Components.format_context(nil, 10_000) == ""
    end

    test "returns empty string when window is nil" do
      assert Components.format_context(1_200, nil) == ""
    end

    test "returns empty string when tokens is zero" do
      assert Components.format_context(0, 10_000) == ""
    end

    test "percentage can exceed 100% when tokens exceeds window" do
      assert Components.format_context(12_000, 10_000) == "ctx 12k / 10k (120%)"
    end
  end
end
