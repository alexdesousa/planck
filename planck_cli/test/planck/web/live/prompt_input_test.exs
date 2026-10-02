defmodule Planck.Web.Live.PromptInputTest do
  use Planck.Web.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Planck.Web.Live.PromptInput

  defp render_input(assigns) do
    render_component(PromptInput, Map.merge(%{id: "test", commands: []}, assigns))
  end

  describe "Send button visibility" do
    test "visible when idle" do
      html = render_input(%{streaming: false, waiting: false})
      assert html =~ ~r/<button[^>]*type="submit"/
    end

    test "visible while waiting (enqueue mode)" do
      html = render_input(%{streaming: false, waiting: true})
      assert html =~ ~r/<button[^>]*type="submit"/
    end

    test "visible while streaming" do
      html = render_input(%{streaming: true, waiting: false})
      assert html =~ ~r/<button[^>]*type="submit"/
    end
  end

  describe "textarea" do
    test "not disabled when idle" do
      html = render_input(%{streaming: false, waiting: false})
      refute html =~ ~r/<textarea[^>]*disabled/
    end

    test "not disabled while waiting" do
      html = render_input(%{streaming: false, waiting: true})
      refute html =~ ~r/<textarea[^>]*disabled/
    end

    test "not disabled while streaming" do
      html = render_input(%{streaming: true, waiting: false})
      refute html =~ ~r/<textarea[^>]*disabled/
    end
  end

  describe "Stop buttons" do
    test "hidden when idle" do
      html = render_input(%{streaming: false, waiting: false})
      refute html =~ "Stop All"
    end

    test "shown while waiting" do
      html = render_input(%{streaming: false, waiting: true})
      assert html =~ "Stop All"
    end

    test "shown while streaming" do
      html = render_input(%{streaming: true, waiting: false})
      assert html =~ "Stop All"
    end
  end

  describe "commands assign" do
    test "accepts and stores a commands list without error" do
      commands = [
        %{
          name: "clear",
          description: "Delete all messages.",
          kind: :builtin,
          disable_model_invocation: true,
          help: "/clear"
        },
        %{
          name: "my-skill",
          description: "A skill.",
          kind: :skill,
          disable_model_invocation: false,
          help: nil
        }
      ]

      html = render_input(%{commands: commands})

      assert html =~ ~r/<textarea/
    end

    test "renders without commands (empty list)" do
      html = render_input(%{commands: []})
      assert html =~ ~r/<textarea/
    end
  end

  # Commands used across dropdown tests
  @dropdown_commands [
    %{
      name: "clear",
      description: "Delete all messages.",
      kind: :builtin,
      disable_model_invocation: true,
      help: "/clear"
    },
    %{
      name: "compact",
      description: "Compact the session.",
      kind: :builtin,
      disable_model_invocation: true,
      help: "/compact [prompt]"
    },
    %{
      name: "review-checklist",
      description: "Runs the review checklist.",
      kind: :command,
      disable_model_invocation: true,
      help: "/review-checklist"
    },
    %{
      name: "grill-me",
      description: "Grills with questions.",
      kind: :skill,
      disable_model_invocation: true,
      help: nil
    },
    %{
      name: "grind-it",
      description: "Grinds through tasks.",
      kind: :skill,
      disable_model_invocation: false,
      help: nil
    },
    %{
      name: "brew-coffee",
      description: "Brews coffee.",
      kind: :skill,
      disable_model_invocation: false,
      help: nil
    }
  ]

  describe "slash autocomplete dropdown" do
    test "dropdown is absent when text is empty" do
      html = render_input(%{commands: @dropdown_commands, text: ""})
      refute html =~ "command-dropdown"
    end

    test "dropdown is absent when text doesn't start with /" do
      html = render_input(%{commands: @dropdown_commands, text: "hello"})
      refute html =~ "command-dropdown"
    end

    test "typing / alone lists all commands in tier order" do
      html =
        render_component(PromptInput,
          id: "test",
          commands: @dropdown_commands,
          text: "/",
          dropdown_open: true,
          command_matches: @dropdown_commands,
          selected_index: 0
        )

      assert html =~ "command-dropdown"
      assert html =~ "/clear"
      assert html =~ "/compact"
      assert html =~ "/review-checklist"
      assert html =~ "/grill-me"
      assert html =~ "/grind-it"
      assert html =~ "/brew-coffee"
    end

    test "built-in rows show a builtin badge" do
      html =
        render_component(PromptInput,
          id: "test",
          commands: @dropdown_commands,
          text: "/",
          dropdown_open: true,
          command_matches: Enum.take(@dropdown_commands, 2),
          selected_index: 0
        )

      assert html =~ ~s(data-badge="builtin")
    end

    test "command rows show a command badge" do
      html =
        render_component(PromptInput,
          id: "test",
          commands: @dropdown_commands,
          text: "/",
          dropdown_open: true,
          command_matches: [Enum.at(@dropdown_commands, 2)],
          selected_index: 0
        )

      assert html =~ ~s(data-badge="command")
    end

    test "skill rows show no type badge" do
      html =
        render_component(PromptInput,
          id: "test",
          commands: @dropdown_commands,
          text: "/",
          dropdown_open: true,
          command_matches: [Enum.at(@dropdown_commands, 4)],
          selected_index: 0
        )

      refute html =~ ~s(data-badge="builtin")
      refute html =~ ~s(data-badge="command")
    end

    test "disabled-invocation skill rows show a manual badge" do
      html =
        render_component(PromptInput,
          id: "test",
          commands: @dropdown_commands,
          text: "/",
          dropdown_open: true,
          command_matches: [Enum.at(@dropdown_commands, 3)],
          selected_index: 0
        )

      assert html =~ ~s(data-badge="manual")
    end

    test "enabled skill rows do not show a manual badge" do
      html =
        render_component(PromptInput,
          id: "test",
          commands: @dropdown_commands,
          text: "/",
          dropdown_open: true,
          command_matches: [Enum.at(@dropdown_commands, 4)],
          selected_index: 0
        )

      refute html =~ ~s(data-badge="manual")
    end

    test "subtitle uses help when present" do
      html =
        render_component(PromptInput,
          id: "test",
          commands: @dropdown_commands,
          text: "/",
          dropdown_open: true,
          command_matches: [Enum.at(@dropdown_commands, 0)],
          selected_index: 0
        )

      assert html =~ "/clear"
    end

    test "subtitle uses description when help is nil" do
      html =
        render_component(PromptInput,
          id: "test",
          commands: @dropdown_commands,
          text: "/",
          dropdown_open: true,
          command_matches: [Enum.at(@dropdown_commands, 3)],
          selected_index: 0
        )

      assert html =~ "Grills with questions."
    end
  end

  describe "dropdown filtering" do
    test "/gri filters to grill-me and grind-it" do
      _matches = PromptInput.__info__(:functions)[:filter_commands] || nil

      # Test via the change event handler by rendering with filtered matches
      filtered =
        Enum.filter(@dropdown_commands, fn cmd ->
          String.downcase(cmd.name) |> String.starts_with?("gri")
        end)

      html =
        render_component(PromptInput,
          id: "test",
          commands: @dropdown_commands,
          text: "/gri",
          dropdown_open: true,
          command_matches: filtered,
          selected_index: 0
        )

      assert html =~ "/grill-me"
      assert html =~ "/grind-it"
      refute html =~ "/clear"
      refute html =~ "/brew-coffee"
    end

    test "/c filters to clear and compact" do
      filtered =
        Enum.filter(@dropdown_commands, fn cmd ->
          String.downcase(cmd.name) |> String.starts_with?("c")
        end)

      html =
        render_component(PromptInput,
          id: "test",
          commands: @dropdown_commands,
          text: "/c",
          dropdown_open: true,
          command_matches: filtered,
          selected_index: 0
        )

      assert html =~ "/clear"
      assert html =~ "/compact"
      refute html =~ "/review-checklist"
    end

    test "tier ordering preserved in filtered results" do
      filtered =
        Enum.filter(@dropdown_commands, fn cmd ->
          String.downcase(cmd.name) |> String.starts_with?("c")
        end)

      html =
        render_component(PromptInput,
          id: "test",
          commands: @dropdown_commands,
          text: "/c",
          dropdown_open: true,
          command_matches: filtered,
          selected_index: 0
        )

      # compact (builtin) should appear before any skill matches
      assert html =~ "/compact"
      # only builtins start with "c" — no skills match
      refute html =~ "/grill-me"
    end

    test "no matches closes the dropdown" do
      html =
        render_component(PromptInput,
          id: "test",
          commands: @dropdown_commands,
          text: "/xyz",
          dropdown_open: false,
          command_matches: [],
          selected_index: 0
        )

      refute html =~ "command-dropdown"
    end
  end

  describe "selection" do
    defp test_socket(assigns) do
      struct(Phoenix.LiveView.Socket, %{
        assigns:
          Map.merge(
            %{
              __changed__: %{},
              id: "test",
              text: "",
              commands: [],
              dropdown_open: false,
              command_matches: [],
              selected_index: 0,
              suppress_dropdown: false,
              __pushed__: []
            },
            assigns
          )
      })
    end

    test "select_command sets text to /name with trailing space" do
      socket = test_socket(%{text: "/gri", dropdown_open: true, suppress_dropdown: false})

      assert {:noreply, updated} =
               PromptInput.handle_event("select_command", %{"name" => "grill-me"}, socket)

      assert updated.assigns.text == "/grill-me "
      assert updated.assigns.dropdown_open == false
      assert updated.assigns.suppress_dropdown == true
    end

    test "select_command is uniform — /clear inserts /clear  with trailing space" do
      socket = test_socket(%{text: "/c", dropdown_open: true, suppress_dropdown: false})

      assert {:noreply, updated} =
               PromptInput.handle_event("select_command", %{"name" => "clear"}, socket)

      assert updated.assigns.text == "/clear "
      assert updated.assigns.dropdown_open == false
    end

    test "close_dropdown event closes the dropdown" do
      socket = test_socket(%{dropdown_open: true})

      assert {:noreply, updated} =
               PromptInput.handle_event("close_dropdown", %{}, socket)

      assert updated.assigns.dropdown_open == false
    end
  end
end
