defmodule Sidecar.Widgets.BeadsTest do
  use ExUnit.Case, async: false

  alias Sidecar.{Config, Widgets.Beads}

  setup do
    bypass = Bypass.open()
    Application.put_env(:sidecar, :beads_url, "http://localhost:#{bypass.port}")
    Application.put_env(:sidecar, :beads_token, "test-token")
    Config.reload_beads_url()
    Config.reload_beads_token()

    on_exit(fn ->
      Application.delete_env(:sidecar, :beads_url)
      Application.delete_env(:sidecar, :beads_token)
      Config.reload_beads_url()
      Config.reload_beads_token()
    end)

    {:ok, bypass: bypass}
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  test "id/0 is the fixed widget id" do
    assert Beads.id() == "beads-board"
  end

  test "container/0 defaults to :modal, from `use Planck.Agent.Widget`" do
    assert Beads.container() == :modal
  end

  describe "render/1" do
    test "fetches open + in_progress + closed as a comma-separated status, not a list",
         %{bypass: bypass} do
      parent = self()

      Bypass.expect_once(bypass, "GET", "/v0/beads/issues", fn conn ->
        send(parent, {:query, conn.query_params})
        json(conn, 200, %{"items" => []})
      end)

      Beads.render(nil)
      assert_receive {:query, %{"status" => "open,in_progress,closed"}}
    end

    test "renders every bead in one list, with a stable id per row", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v0/beads/issues", fn conn ->
        json(conn, 200, %{
          "items" => [
            %{
              "id" => "bd-2",
              "title" => "Doing this",
              "status" => "in_progress",
              "assignee" => "team:worker-1"
            },
            %{"id" => "bd-1", "title" => "Todo item", "status" => "open"}
          ]
        })
      end)

      html = Beads.render(nil)
      assert html =~ ~s(id="bead-bd-1")
      assert html =~ ~s(id="bead-bd-2")
      assert html =~ "bd-1: Todo item"
      assert html =~ "bd-2: Doing this"
      assert html =~ "team:worker-1"
    end

    test "shows a bead's description when present", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v0/beads/issues", fn conn ->
        json(conn, 200, %{
          "items" => [%{"id" => "bd-1", "title" => "Todo item", "description" => "More context"}]
        })
      end)

      html = Beads.render(nil)
      assert html =~ "More context"
    end

    test "renders an empty list without crashing when the fetch fails", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/v0/beads/issues", &json(&1, 500, %{"error" => "boom"}))

      html = Beads.render(nil)
      assert html =~ "none"
    end

    test "the create form collects title, description, and priority", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/v0/beads/issues", &json(&1, 200, %{"items" => []}))

      html = Beads.render(nil)
      assert html =~ ~s(name="args[title]")
      assert html =~ ~s(name="args[description]")
      assert html =~ ~s(name="args[priority]")
      assert html =~ ~s(value="user")
    end

    test "priority is the app's own dropdown look, not a native select, defaulting to P2",
         %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/v0/beads/issues", &json(&1, 200, %{"items" => []}))

      html = Beads.render(nil)
      refute html =~ "<select"
      assert html =~ ~s(phx-hook="FloatingDropdown")
      assert html =~ ~s(data-label="P2")
      assert html =~ "P0 — critical"
      assert html =~ "P4 — lowest"
    end

    test "there is no per-row assignee control — assignment is LLM-only", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v0/beads/issues", fn conn ->
        json(conn, 200, %{
          "items" => [%{"id" => "bd-1", "title" => "Todo item", "assignee" => "team:worker-1"}]
        })
      end)

      html = Beads.render(nil)
      refute html =~ ~s(name="args[assignee]")
      refute html =~ "Claim"
    end

    test "there is no done checkbox — closing a bead is LLM-only", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v0/beads/issues", fn conn ->
        json(conn, 200, %{"items" => [%{"id" => "bd-1", "title" => "Todo item"}]})
      end)

      html = Beads.render(nil)
      refute html =~ ~s(type="checkbox")
    end

    test "Create is styled like the chat input's Send button", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/v0/beads/issues", &json(&1, 200, %{"items" => []}))

      html = Beads.render(nil)
      assert html =~ "bg-primary"
      assert html =~ "text-primary-foreground"
    end

    test "Delete is styled like the chat input's Stop button", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v0/beads/issues", fn conn ->
        json(conn, 200, %{"items" => [%{"id" => "bd-1", "title" => "Todo item"}]})
      end)

      html = Beads.render(nil)
      assert html =~ "bg-destructive"
      assert html =~ "text-destructive-foreground"
    end

    test "status: open when not closed and not assigned", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v0/beads/issues", fn conn ->
        json(conn, 200, %{"items" => [%{"id" => "bd-1", "title" => "Todo item"}]})
      end)

      html = Beads.render(nil)
      assert html =~ "open"
    end

    test "status: in progress when assigned but not closed", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v0/beads/issues", fn conn ->
        json(conn, 200, %{
          "items" => [%{"id" => "bd-1", "title" => "Todo item", "assignee" => "team:worker-1"}]
        })
      end)

      html = Beads.render(nil)
      assert html =~ "in progress"
    end

    test "status: done when closed, regardless of assignee", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v0/beads/issues", fn conn ->
        json(conn, 200, %{
          "items" => [
            %{"id" => "bd-1", "title" => "Todo item", "status" => "closed"},
            %{
              "id" => "bd-2",
              "title" => "Also done",
              "status" => "closed",
              "assignee" => "team:worker-1"
            }
          ]
        })
      end)

      html = Beads.render(nil)
      assert html =~ ~s(id="bead-bd-1-delete")
      assert html =~ ~s(id="bead-bd-2-delete")
      refute html =~ "in progress"
    end
  end

  describe "render/2 — locale" do
    setup do
      # :persistent_term is process/VM-global, not per-test — every test here
      # must restore "en" on exit, or it leaks into every test that runs
      # after it, in this file and any other.
      on_exit(fn -> Planck.Agent.Sidecar.set_locale("en") end)
      :ok
    end

    test "renders in the locale Planck.Agent.Sidecar.get_locale/0 reports", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/v0/beads/issues", &json(&1, 200, %{"items" => []}))

      Planck.Agent.Sidecar.set_locale("es")
      html = Beads.render(nil)

      assert html =~ "Crear"
      assert html =~ "Nueva tarea"
      refute html =~ ">Create<"
    end

    test "defaults to English when no locale was ever pushed", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/v0/beads/issues", &json(&1, 200, %{"items" => []}))

      html = Beads.render(nil)

      assert html =~ "Create"
      assert html =~ "New task"
    end

    test "translates the fixed status labels", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v0/beads/issues", fn conn ->
        json(conn, 200, %{
          "items" => [
            %{"id" => "bd-1", "title" => "Open one"},
            %{"id" => "bd-2", "title" => "In progress one", "assignee" => "team:worker-1"},
            %{"id" => "bd-3", "title" => "Done one", "status" => "closed"}
          ]
        })
      end)

      Planck.Agent.Sidecar.set_locale("es")
      html = Beads.render(nil)

      assert html =~ "abierto"
      assert html =~ "en curso"
      assert html =~ "hecho"
    end
  end

  describe "handle_action/2" do
    setup do
      Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "sidecar:widget:beads-board")
      :ok
    end

    test "create posts title, description, and priority, then broadcasts a refresh",
         %{bypass: bypass} do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v0/beads/issues", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:create_body, Jason.decode!(body)})
        json(conn, 200, %{"id" => "bd-9"})
      end)

      Bypass.expect(bypass, "GET", "/v0/beads/issues", &json(&1, 200, %{"items" => []}))

      assert :ok =
               Beads.handle_action("create", %{
                 "title" => "New task",
                 "description" => "Some context",
                 "priority" => "1",
                 "actor" => "user"
               })

      assert_receive {:create_body, body}
      assert body["title"] == "New task"
      assert body["description"] == "Some context"
      assert body["priority"] == 1
      assert body["actor"] == "user"
      assert_receive {:widget_rendered, "beads-board", _html}
    end

    test "create omits description/priority entirely when left blank", %{bypass: bypass} do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v0/beads/issues", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:create_body, Jason.decode!(body)})
        json(conn, 200, %{"id" => "bd-9"})
      end)

      Bypass.expect(bypass, "GET", "/v0/beads/issues", &json(&1, 200, %{"items" => []}))

      assert :ok =
               Beads.handle_action("create", %{
                 "title" => "New task",
                 "description" => "",
                 "priority" => "",
                 "actor" => "user"
               })

      assert_receive {:create_body, body}
      refute Map.has_key?(body, "description")
      refute Map.has_key?(body, "priority")
    end

    test "delete posts to the batch-delete endpoint and broadcasts a refresh", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v0/beads/issues:delete", fn conn ->
        json(conn, 200, %{})
      end)

      Bypass.expect(bypass, "GET", "/v0/beads/issues", &json(&1, 200, %{"items" => []}))

      assert :ok = Beads.handle_action("delete", %{"id" => "bd-1", "actor" => "user"})
      assert_receive {:widget_rendered, "beads-board", _html}
    end

    test "returns the error tuple and does not broadcast when the write fails", %{bypass: bypass} do
      Bypass.stub(
        bypass,
        "POST",
        "/v0/beads/issues:delete",
        &json(&1, 400, %{"error" => "has a dependent"})
      )

      assert {:error, {400, %{"error" => "has a dependent"}}} =
               Beads.handle_action("delete", %{"id" => "bd-1", "actor" => "user"})

      refute_receive {:widget_rendered, "beads-board", _html}
    end
  end
end
