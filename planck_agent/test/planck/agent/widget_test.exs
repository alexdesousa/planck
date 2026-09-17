defmodule Planck.Agent.WidgetTest do
  use ExUnit.Case, async: true

  alias Planck.Agent.Widget

  defmodule DefaultContainerWidget do
    use Widget

    @impl true
    def id, do: "default-container"

    @impl true
    def render(_myself), do: "<div/>"

    @impl true
    def handle_action(_action, _args), do: :ok
  end

  defmodule DrawerWidget do
    use Widget

    @impl true
    def id, do: "drawer"

    @impl true
    def render(_myself), do: "<div/>"

    @impl true
    def handle_action(_action, _args), do: :ok

    @impl true
    def container, do: :drawer
  end

  defmodule RawBehaviourWidget do
    @behaviour Widget

    @impl true
    def id, do: "raw-behaviour"

    @impl true
    def render(_myself), do: "<div/>"

    @impl true
    def handle_action(_action, _args), do: :ok
  end

  describe "use Planck.Agent.Widget" do
    test "injects a container/0 that returns :modal, called directly, no dispatch involved" do
      assert DefaultContainerWidget.container() == :modal
    end

    test "the injected default is overridable" do
      assert DrawerWidget.container() == :drawer
    end
  end

  describe "a widget implementing the behaviour by hand (no use)" do
    test "container/0 raises when called directly if it wasn't also defined by hand" do
      # apply/3, not a direct call — the compiler statically knows
      # RawBehaviourWidget.container/0 doesn't exist and would flag a direct
      # call as a compile-time warning (this project treats warnings as
      # errors), even though the point of this test is exactly that it
      # doesn't exist.
      assert_raise UndefinedFunctionError, fn -> apply(RawBehaviourWidget, :container, []) end
    end
  end
end
