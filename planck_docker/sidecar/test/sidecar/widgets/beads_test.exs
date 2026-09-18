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
    test "fetches open + in_progress as a comma-separated status, not a list", %{bypass: bypass} do
      parent = self()

      Bypass.expect_once(bypass, "GET", "/v0/beads/issues", fn conn ->
        send(parent, {:query, conn.query_params})
        json(conn, 200, %{"items" => []})
      end)

      Beads.render(nil)
      assert_receive {:query, %{"status" => "open,in_progress"}}
    end

    test "renders beads under fixed open/in_progress columns, always both, in that order",
         %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v0/beads/issues", fn conn ->
        json(conn, 200, %{
          "items" => [
            %{
              "id" => "bd-2",
              "title" => "Doing this",
              "status" => "in_progress",
              "priority" => 2,
              "assignee" => "team:worker-1"
            },
            %{"id" => "bd-1", "title" => "Todo item", "status" => "open", "priority" => 1}
          ]
        })
      end)

      html = Beads.render(nil)
      assert html =~ "bd-1: Todo item"
      assert html =~ "bd-2: Doing this"
      assert html =~ "team:worker-1"
      # Column headers are the translated label, not the raw API status —
      # "in progress" (a space), not "in_progress" (the group_by/1 key).
      assert html =~ "open"
      assert html =~ "in progress"
    end

    test "renders empty columns without crashing when the fetch fails", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/v0/beads/issues", &json(&1, 500, %{"error" => "boom"}))

      html = Beads.render(nil)
      assert html =~ "none"
    end

    test "the claim control is a form collecting a free-text assignee, not a picker",
         %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v0/beads/issues", fn conn ->
        json(conn, 200, %{
          "items" => [%{"id" => "bd-1", "title" => "Todo item", "status" => "open"}]
        })
      end)

      html = Beads.render(nil)
      assert html =~ ~s(name="args[assignee]")
      assert html =~ ~s(name="args[id]" value="bd-1")
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

    test "translates the fixed status column headers", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/v0/beads/issues", &json(&1, 200, %{"items" => []}))

      Planck.Agent.Sidecar.set_locale("es")
      html = Beads.render(nil)

      assert html =~ "abierto"
      assert html =~ "en curso"
    end
  end

  describe "handle_action/2" do
    setup do
      Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "sidecar:widget:beads-board")
      :ok
    end

    test "claim posts to the claim endpoint and broadcasts a refresh", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v0/beads/issues/bd-1:claim", fn conn ->
        json(conn, 200, %{"issue" => %{"id" => "bd-1"}})
      end)

      Bypass.expect(bypass, "GET", "/v0/beads/issues", &json(&1, 200, %{"items" => []}))

      assert :ok = Beads.handle_action("claim", %{"id" => "bd-1", "assignee" => "human"})
      assert_receive {:widget_rendered, "beads-board", _html}
    end

    test "create posts to the issues endpoint and broadcasts a refresh", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v0/beads/issues", fn conn ->
        json(conn, 200, %{"id" => "bd-9"})
      end)

      Bypass.expect(bypass, "GET", "/v0/beads/issues", &json(&1, 200, %{"items" => []}))

      assert :ok = Beads.handle_action("create", %{"title" => "New task", "actor" => "human"})
      assert_receive {:widget_rendered, "beads-board", _html}
    end

    test "done posts to the close endpoint and broadcasts a refresh", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v0/beads/issues/bd-1:close", fn conn ->
        json(conn, 200, %{"issue" => %{"id" => "bd-1"}})
      end)

      Bypass.expect(bypass, "GET", "/v0/beads/issues", &json(&1, 200, %{"items" => []}))

      assert :ok = Beads.handle_action("done", %{"id" => "bd-1", "actor" => "human"})
      assert_receive {:widget_rendered, "beads-board", _html}
    end

    test "delete posts to the batch-delete endpoint and broadcasts a refresh", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v0/beads/issues:delete", fn conn ->
        json(conn, 200, %{})
      end)

      Bypass.expect(bypass, "GET", "/v0/beads/issues", &json(&1, 200, %{"items" => []}))

      assert :ok = Beads.handle_action("delete", %{"id" => "bd-1", "actor" => "human"})
      assert_receive {:widget_rendered, "beads-board", _html}
    end

    test "returns the error tuple and does not broadcast when the write fails", %{bypass: bypass} do
      Bypass.stub(
        bypass,
        "POST",
        "/v0/beads/issues/bd-1:claim",
        &json(&1, 409, %{"assignee" => "x"})
      )

      assert {:error, {409, %{"assignee" => "x"}}} =
               Beads.handle_action("claim", %{"id" => "bd-1", "assignee" => "human"})

      refute_receive {:widget_rendered, "beads-board", _html}
    end
  end
end
