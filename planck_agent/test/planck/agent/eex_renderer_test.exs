defmodule Planck.Agent.EExRendererTest do
  use ExUnit.Case, async: true

  alias Planck.Agent.EExRenderer

  describe "render/2" do
    test "renders a template with present bindings" do
      template = "Hello, <%= name %>!"
      assert EExRenderer.render(template, name: "world") == "Hello, world!"
    end

    test "renders a template with nil bindings via if-guard" do
      template = "<%= if prompt do %>Focus: <%= prompt %><% end %>Done."
      assert EExRenderer.render(template, prompt: nil) == "Done."
    end

    test "renders a template with a present binding via if-guard" do
      template = "<%= if prompt do %>Focus: <%= prompt %><% end %>Done."
      assert EExRenderer.render(template, prompt: "API design") == "Focus: API designDone."
    end

    test "raises on truly unbound variables" do
      template = "Value: <%= missing %>"

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert_raise CompileError, fn ->
          EExRenderer.render(template, [])
        end
      end)
    end

    test "renders a multi-line command body template" do
      template = """
      # Review Checklist

      You are reviewing: <%= args %>

      Be thorough.
      """

      rendered = EExRenderer.render(template, args: "src/auth")
      assert rendered =~ "You are reviewing: src/auth"
      assert rendered =~ "Be thorough."
    end

    test "renders with args nil" do
      template = "Args: <%= args %>"
      assert EExRenderer.render(template, args: nil) == "Args: "
    end
  end
end
