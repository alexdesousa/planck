defmodule Sidecar.Widgets.Beads do
  @moduledoc """
  Renders the shared beads (task) board and handles clicks from it.

  Paired with the `bd_ready` tool via its `:widget` field (`Sidecar.Tools.BeadsReady`).
  `use Phoenix.Component` is this module's own choice — `planck_agent` neither
  requires nor knows about it; see `c:Planck.Agent.Widget.render/1`'s moduledoc.

  ## Assignee/actor identity is a plain text field here, not a live picker

  A human clicking in the widget needs to name who a claim goes to, or who's
  acting for an audit trail — unlike an LLM tool call, there's no runtime
  `agent_id` to resolve identity from (see `Sidecar.Tools.Beads.resolve_actor/1`).
  The original design called for a picker sourced from the live agent
  registry (`Registry.lookup(Planck.Agent.Registry, {team_id, :member})`),
  but that registry runs on the `planck_headless` node, not this sidecar
  node — `render/1` executes here, with no local access to it, and reaching
  across would mean the widget calling back into the connected headless node
  by name, not just answering a call from it. Free-text input for now;
  wiring an actual picker is follow-up work, not solved in this pass.

  For the same reason, the create form here only collects a title — unlike
  `bd_create` (the LLM tool), which also accepts `description`/`priority`.
  Nothing structural blocks adding those two fields to the form; they're
  just left out of this first pass.

  ## Translated via `Sidecar.Gettext`, not `Planck.Web.Gettext`

  This module's own labels (buttons, placeholders, status names) are
  translated with the sidecar's own Gettext backend — see its moduledoc for
  why a separate catalog from `planck_cli`'s is a real constraint, not a
  preference. `render/2` sets the process-local Gettext locale from
  `Planck.Agent.Sidecar.get_locale/0` on every call, since a widget render
  is stateless from one call to the next and has no other way to know
  which locale to use.

  ## `render/2`

  `render/1` — the actual `Planck.Agent.Widget` behaviour callback, the one
  real dispatch ever calls — is a thin wrapper over `render/2`, which also
  takes `Sidecar.Beads`'s `:client` opt. This exists solely so
  `Sidecar.Beads.broadcast_refresh/1` can re-render against an injected test
  client without the behaviour callback itself gaining a second argument
  every widget kind would have to carry.
  """

  use Phoenix.Component
  use Planck.Agent.Widget
  use Gettext, backend: Sidecar.Gettext

  @column_order ["open", "in_progress"]

  @impl true
  def id, do: "beads-board"

  @impl true
  def render(myself), do: render(myself, [])

  @doc false
  @spec render(term(), keyword()) :: String.t()
  def render(myself, opts) do
    Gettext.put_locale(Sidecar.Gettext, Planck.Agent.Sidecar.get_locale())
    assigns = %{columns: fetch_columns(opts), myself: myself}

    ~H"""
    <div class="space-y-4 text-sm">
      <form phx-submit="widget_action" phx-target={@myself} class="flex gap-2 items-end border-b-2 border-border pb-3">
        <input type="hidden" name="action" value="create" />
        <input type="hidden" name="args[actor]" value="human" />
        <div class="flex-1">
          <label class="block text-xs font-bold mb-1">{pgettext("bead widget", "New task")}</label>
          <input
            type="text"
            name="args[title]"
            placeholder={pgettext("bead widget", "Title")}
            required
            class="w-full border-2 border-border px-2 py-1 text-xs"
          />
        </div>
        <button type="submit" class="border-2 border-black px-3 py-1 text-xs font-bold bg-card">
          {pgettext("button label", "Create")}
        </button>
      </form>

      <div class="grid grid-cols-2 gap-3">
        <div :for={{status, beads} <- @columns} class="border-2 border-border p-2">
          <p class="font-bold text-xs uppercase mb-2">{status_label(status)}</p>

          <p :if={beads == []} class="text-xs text-muted-foreground italic">
            {pgettext("bead widget", "none")}
          </p>

          <div :for={bead <- beads} class="border-b border-border pb-2 mb-2 last:border-b-0">
            <p class="text-xs font-bold">{bead["id"]}: {bead["title"]}</p>
            <p class="text-xs text-muted-foreground">
              {pgettext("bead widget", "priority")} {bead["priority"]}<span :if={bead["assignee"]}> · {bead["assignee"]}</span>
            </p>
            <div class="flex gap-1 mt-1 items-center">
              <form phx-submit="widget_action" phx-target={@myself} class="flex gap-1">
                <input type="hidden" name="action" value="claim" />
                <input type="hidden" name="args[id]" value={bead["id"]} />
                <input
                  type="text"
                  name="args[assignee]"
                  placeholder={pgettext("bead widget", "assignee")}
                  required
                  class="border border-border px-1 text-xs w-24"
                />
                <button type="submit" class="border border-black px-2 text-xs">
                  {pgettext("button label", "Claim")}
                </button>
              </form>
              <button
                phx-click={
                  Phoenix.LiveView.JS.push("widget_action",
                    value: %{action: "done", args: %{id: bead["id"], actor: "human"}},
                    target: @myself
                  )
                }
                class="border border-black px-2 text-xs"
              >
                {pgettext("button label", "Done")}
              </button>
              <button
                phx-click={
                  Phoenix.LiveView.JS.push("widget_action",
                    value: %{action: "delete", args: %{id: bead["id"], actor: "human"}},
                    target: @myself
                  )
                }
                class="border border-black px-2 text-xs text-destructive"
              >
                {pgettext("button label", "Delete")}
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  @impl true
  def handle_action("claim", %{"id" => id, "assignee" => assignee}) do
    with {:ok, _} <- Sidecar.Beads.claim(id, assignee) do
      Sidecar.Beads.broadcast_refresh()
      :ok
    end
  end

  def handle_action("create", %{"title" => title, "actor" => actor}) do
    with {:ok, _} <- Sidecar.Beads.create(title, actor) do
      Sidecar.Beads.broadcast_refresh()
      :ok
    end
  end

  def handle_action("delete", %{"id" => id, "actor" => actor}) do
    with {:ok, _} <- Sidecar.Beads.delete([id], actor) do
      Sidecar.Beads.broadcast_refresh()
      :ok
    end
  end

  def handle_action("done", %{"id" => id, "actor" => actor}) do
    with {:ok, _} <- Sidecar.Beads.close(id, actor) do
      Sidecar.Beads.broadcast_refresh()
      :ok
    end
  end

  # @column_order only ever holds "open"/"in_progress" today, so the
  # fallback clause is dead for now — kept anyway, since a status string is
  # API-controlled data, not a closed set this module gets to assume.
  @spec status_label(String.t()) :: String.t()
  defp status_label("open"), do: pgettext("bead status", "open")
  defp status_label("in_progress"), do: pgettext("bead status", "in progress")
  defp status_label(status), do: status

  # Sidecar.Beads.list/1's status filter — a comma-separated string, NOT a
  # list. Req's params: option calls URI.encode_query/1 directly (checked
  # its source), which raises ArgumentError on a list value outright; the
  # OpenAPI spec documents the comma-separated form (`style: form,
  # explode: true` also accepts one repeated-or-joined value) as an
  # equally valid alternative to repeating the parameter.
  @spec fetch_columns(keyword()) :: [{String.t(), [map()]}]
  defp fetch_columns(opts) do
    list_opts = [status: "open,in_progress"] ++ Keyword.take(opts, [:client])

    case Sidecar.Beads.list(list_opts) do
      {:ok, %{"items" => items}} ->
        by_status = Enum.group_by(items, & &1["status"])
        Enum.map(@column_order, &{&1, Map.get(by_status, &1, [])})

      {:error, _reason} ->
        Enum.map(@column_order, &{&1, []})
    end
  end
end
