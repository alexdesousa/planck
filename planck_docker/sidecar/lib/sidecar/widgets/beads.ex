defmodule Sidecar.Widgets.Beads do
  @moduledoc """
  Renders the shared beads (task) board and handles clicks from it.

  Paired with the `bd_ready` tool via its `:widget` field (`Sidecar.Tools.BeadsReady`).
  `use Phoenix.Component` is this module's own choice — `planck_agent` neither
  requires nor knows about it; see `c:Planck.Agent.Widget.render/1`'s moduledoc.

  ## No assignee control, no done checkbox — a human only creates and deletes

  Workers are spawned and torn down by the orchestrator at its own
  discretion; a worker doesn't pull tasks off this board itself, and a
  specific worker id a human might see right now can be gone by the time
  anyone looks again. Picking a named worker from this widget would bypass
  the orchestrator's own delegation entirely and could easily point at a
  process that no longer exists. Marking a bead done from here has the same
  problem one level up: the orchestrator (or whichever agent it delegated
  to) is the one that knows whether the work is actually finished, not a
  human eyeballing a title. So this board only lets a human create and
  delete — never assign, never close. Claiming (via `bd_claim`) and closing
  (via `bd_done`) both stay LLM-only actions, resolved through
  `Sidecar.Tools.Beads.resolve_actor/1` the normal way and never routed
  through this module's own `handle_action/2`; a bead's `assignee` and
  `status`, when set, are shown here as plain read-only text/labels.

  ## Every human-triggered action here is actor `"user"`

  Unlike an LLM tool call, there's no runtime `agent_id` to resolve identity
  from for a click that originates in this widget — every create/delete
  here is recorded as actor `"user"`, a fixed, well-known string (not a
  live picker, not free text).

  The create form here also collects `description`/`priority`, matching
  what the LLM-facing `bd_create` tool already accepts.

  ## Priority's dropdown looks like `Planck.Web.Components.dropdown/1`, but isn't one

  `dropdown/1` updates its visible label by pushing an event to a
  `@selected` assign a *stateful* LiveComponent owns. This widget has
  nowhere to hold that kind of per-viewer, not-yet-submitted state —
  `render/2` is stateless and its output is broadcast identically to every
  subscriber (see `Sidecar.Beads.broadcast_refresh/1`), so a value picked
  here before `Create` is pressed has to live in the browser alone, exactly
  like the plain `title`/`description` fields already do. `priority_dropdown/1`
  (private, below) copies `dropdown/1`'s markup, classes, and its
  `FloatingDropdown` hook (already loaded — the hook is generic over any
  element with that `phx-hook`, regardless of which module rendered it, so
  reusing it here needed no change to `planck_cli`'s own JS), but updates
  the label with `JS.set_attribute` writing a `data-label` attribute instead
  of a server round-trip, paired with the `[data-label]::before` CSS rule
  at the top of `render/2`. No new hook, no new server-side event, no
  per-viewer state — just a client-side stand-in for what a round-trip
  would otherwise do.

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

  ## Every bead row and its controls carry an explicit, stable `id`

  This whole board is one opaque HTML string as far as `SidecarWidget`'s own
  HEEx template is concerned (`Phoenix.HTML.raw/1` around a plain string) —
  there's no `:for`-comprehension for the client's diffing to key by, since
  that comprehension already ran, server-side, before flattening to a
  string. Without a stable `id` on each row, the client patches a changed
  board by DOM *position*, not bead identity: deleting one bead shifts every
  row after it up by one slot, and a position-based patch can reuse a
  stale element (and its already-bound click handler) for the wrong bead —
  reported as "delete one bead, then clicking a *different* one closes the
  whole widget instead." Explicit ids matching a live bead's actual data on
  every render side-step that entirely.

  ## Tailwind now scans this module's source directly

  `planck_cli`'s `app.css` disables Tailwind's default content
  auto-detection (`@import "tailwindcss" source(none)`) and only compiles
  classes found under its own explicit `@source` list — which, until this
  widget's redesign, did not include `planck_docker/sidecar/lib` at all,
  since it's a different Mix project entirely. A class used here that
  didn't *also* happen to appear verbatim somewhere already scanned got
  silently purged from the compiled CSS with no error anywhere — real risk
  for a from-scratch layout like this one. `@source "../../../planck_docker/sidecar/lib"`
  was added to `planck_cli/assets/css/app.css` alongside this redesign, so
  ordinary Tailwind classes here are compiled like any other — including
  `priority_dropdown/1`'s copy of `dropdown/1`'s own classes, which
  wouldn't have survived the purge before that `@source` line existed.
  """

  use Phoenix.Component
  use Planck.Agent.Widget
  use Gettext, backend: Sidecar.Gettext

  alias Phoenix.LiveView.JS

  @priority_options [
    {"0", "P0 — critical"},
    {"1", "P1"},
    {"2", "P2"},
    {"3", "P3"},
    {"4", "P4 — lowest"}
  ]

  @impl true
  def id, do: "beads-board"

  @impl true
  def render(myself), do: render(myself, [])

  @doc false
  @spec render(term(), keyword()) :: String.t()
  def render(myself, opts) do
    Gettext.put_locale(Sidecar.Gettext, Planck.Agent.Sidecar.get_locale())
    assigns = %{beads: fetch_beads(opts), priority_options: @priority_options, myself: myself}

    ~H"""
    <div class="space-y-3 text-sm">
      <style>[data-label]::before { content: attr(data-label); }</style>
      <form phx-submit="widget_action" phx-target={@myself} class="border-2 border-border p-2 space-y-2">
        <input type="hidden" name="action" value="create" />
        <input type="hidden" name="args[actor]" value="user" />
        <p class="font-bold text-xs uppercase">{pgettext("bead widget", "New task")}</p>
        <div class="flex gap-2">
          <input
            type="text"
            name="args[title]"
            placeholder={pgettext("bead widget", "Title")}
            required
            class="flex-1 border-2 border-border px-2 py-1 text-xs"
          />
          <.priority_dropdown id="beads-new-priority" options={@priority_options} />
        </div>
        <textarea
          name="args[description]"
          placeholder={pgettext("bead widget", "Description")}
          rows="2"
          class="w-full border-2 border-border px-2 py-1 text-xs"
        ></textarea>
        <div class="flex justify-end">
          <button
            type="submit"
            class="border-2 border-black px-4 py-1 font-bold font-mono text-xs
                   shadow-[2px_2px_0px_#000] hover:shadow-[4px_4px_0px_#000]
                   hover:-translate-x-0.5 hover:-translate-y-0.5 transition-all
                   bg-primary text-primary-foreground"
          >
            {pgettext("button label", "Create")}
          </button>
        </div>
      </form>

      <p :if={@beads == []} class="text-xs text-muted-foreground italic">
        {pgettext("bead widget", "none")}
      </p>

      <div :if={@beads != []} class="max-h-72 overflow-y-auto space-y-2">
        <div :for={bead <- @beads} id={"bead-#{bead["id"]}"} class="border-2 border-border p-2 space-y-1">
          <div class="flex items-start justify-between gap-2">
            <p class={["text-xs font-bold", bead["status"] == "closed" && "line-through opacity-50"]}>
              {bead["id"]}: {bead["title"]}
            </p>
            <span class={["shrink-0 border-2 border-border px-1 text-xs font-bold uppercase", pill_class(bead)]}>
              {status_label(bead)}
            </span>
          </div>

          <div
            :if={bead["description"] not in [nil, ""]}
            class={["text-xs text-muted-foreground", bead["status"] == "closed" && "line-through opacity-50"]}
          >
            {render_description(bead["description"])}
          </div>

          <div class="flex items-center justify-between gap-2">
            <p class="text-xs font-bold">
              {if bead["assignee"], do: "#{pgettext("bead widget", "assigned to")} #{bead["assignee"]}"}
            </p>
            <button
              id={"bead-#{bead["id"]}-delete"}
              phx-click={
                JS.push("widget_action",
                  value: %{action: "delete", args: %{id: bead["id"], actor: "user"}},
                  target: @myself
                )
              }
              class="shrink-0 border-2 border-black px-3 py-1 font-bold font-mono text-xs
                     shadow-[2px_2px_0px_#000] hover:shadow-[4px_4px_0px_#000]
                     hover:-translate-x-0.5 hover:-translate-y-0.5 transition-all
                     bg-destructive text-destructive-foreground"
            >
              {pgettext("button label", "Delete")}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  # Same trigger/panel/backdrop shape and classes as
  # Planck.Web.Components.dropdown/1 (border-2/hard-shadow trigger, a
  # position:fixed options panel repositioned by the same already-loaded
  # `FloatingDropdown` hook — see that component's own moduledoc for why
  # `position: fixed` matters there) — but selecting an option here never
  # pushes a server event. dropdown/1 updates its visible label by pushing
  # to a `@selected` assign a *stateful* LiveComponent owns; this widget's
  # render/2 is stateless and broadcasts the identical HTML to every
  # subscriber at once (see Sidecar.Beads.broadcast_refresh/1), so there's
  # nowhere to hold "picked but not yet submitted" per-viewer state the way
  # dropdown/1 does. Instead, JS.set_attribute updates a plain `data-label`
  # attribute purely client-side, and the `[data-label]::before` rule near
  # the top of render/2 displays it — the same trick, in effect, as
  # dropdown/1's server round-trip, without needing one.
  defp priority_dropdown(assigns) do
    default_value = "2"

    default_label =
      Enum.find_value(assigns.options, fn {v, l} -> if v == default_value, do: l end)

    assigns =
      assigns
      |> assign(:default_value, default_value)
      |> assign(:default_label, default_label)

    ~H"""
    <div id={@id} class="relative shrink-0" phx-hook="FloatingDropdown">
      <input type="hidden" name="args[priority]" id={"#{@id}-value"} value={@default_value} />
      <button
        type="button"
        class="flex items-center gap-2 border-2 border-black px-2 py-1 font-mono text-xs font-bold
               bg-card shadow-[2px_2px_0px_#000] hover:shadow-[4px_4px_0px_#000]
               hover:-translate-x-0.5 hover:-translate-y-0.5 transition-all text-left"
        phx-click={JS.show(to: "##{@id}-panel") |> JS.show(to: "##{@id}-backdrop")}
      >
        <span id={"#{@id}-label"} data-label={@default_label}></span>
        <span class="text-muted-foreground text-xs">▼</span>
      </button>

      <div
        id={"#{@id}-backdrop"}
        class="fixed inset-0 z-40"
        style="display: none"
        phx-click={JS.hide(to: "##{@id}-panel") |> JS.hide(to: "##{@id}-backdrop")}
      />

      <div
        id={"#{@id}-panel"}
        class="fixed z-[9999] mt-1 border-2 border-black bg-card shadow-[4px_4px_0px_#000] max-h-48 overflow-y-auto"
        style="display: none"
      >
        <button
          :for={{value, label} <- @options}
          type="button"
          class="w-full text-left px-2 py-1 font-mono text-xs border-b-2 border-black last:border-0 bg-card hover:bg-muted"
          phx-click={
            JS.hide(to: "##{@id}-panel")
            |> JS.hide(to: "##{@id}-backdrop")
            |> JS.set_attribute({"value", value}, to: "##{@id}-value")
            |> JS.set_attribute({"data-label", label}, to: "##{@id}-label")
          }
        >
          {label}
        </button>
      </div>
    </div>
    """
  end

  @impl true
  def handle_action("create", %{"title" => title, "actor" => actor} = args) do
    opts =
      []
      |> maybe_put_opt(:description, args["description"])
      |> maybe_put_opt(:priority, args["priority"])

    with {:ok, _} <- Sidecar.Beads.create(title, actor, opts) do
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

  # A blank string from an unfilled optional form field means "not
  # provided," same as the field being absent — Sidecar.Beads.create/3
  # already drops a nil value via its own maybe_put, so normalizing "" to
  # nil here is enough; no separate "was this key sent at all" branch needed.
  @spec maybe_put_opt(keyword(), atom(), String.t() | nil) :: keyword()
  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, _key, ""), do: opts

  defp maybe_put_opt(opts, :priority, value),
    do: Keyword.put(opts, :priority, String.to_integer(value))

  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  # Same MDEx call/opts as Planck.Web.Live.ChatComponent.render_markdown/1 —
  # a bead's description is agent-authored free text, exactly like chat
  # messages, and needs the same XSS-safe treatment (MDEx replaced Earmark
  # there after an active CVE; see that function's own moduledoc reference).
  # Falls back to the raw, HTML-escaped text on a render error rather than
  # ever emitting unsanitized input.
  @spec render_description(String.t()) :: Phoenix.HTML.safe()
  defp render_description(text) do
    case MDEx.to_html(text, extension: [table: true, autolink: true], render: [hardbreaks: true]) do
      {:ok, html} -> Phoenix.HTML.raw(html)
      _ -> Phoenix.HTML.html_escape(text)
    end
  end

  # Mirrors the human-facing rule the widget was designed against: a bead
  # not yet closed and with no assignee reads as "open"; claimed-but-open
  # reads as "in progress" (set by an agent's own bd_claim call — never by
  # this widget, see the moduledoc); closed always reads as "done"
  # regardless of who, if anyone, held it.
  @spec status_label(map()) :: String.t()
  defp status_label(bead)
  defp status_label(%{"status" => "closed"}), do: pgettext("bead status", "done")

  defp status_label(%{"assignee" => a}) when is_binary(a) and a != "",
    do: pgettext("bead status", "in progress")

  defp status_label(_bead), do: pgettext("bead status", "open")

  @spec pill_class(map()) :: String.t()
  defp pill_class(bead)
  defp pill_class(%{"status" => "closed"}), do: "bg-primary text-primary-foreground"

  defp pill_class(%{"assignee" => a}) when is_binary(a) and a != "",
    do: "bg-accent text-foreground"

  defp pill_class(_bead), do: "bg-card text-muted-foreground"

  # Sidecar.Beads.list/1's status filter — a comma-separated string, NOT a
  # list. Req's params: option calls URI.encode_query/1 directly (checked
  # its source), which raises ArgumentError on a list value outright; the
  # OpenAPI spec documents the comma-separated form (`style: form,
  # explode: true` also accepts one repeated-or-joined value) as an
  # equally valid alternative to repeating the parameter. All three
  # statuses are fetched (not just open/in_progress) — closed beads still
  # need to render, struck through, not disappear from the board the
  # moment an agent marks them done.
  @spec fetch_beads(keyword()) :: [map()]
  defp fetch_beads(opts) do
    list_opts = [status: "open,in_progress,closed"] ++ Keyword.take(opts, [:client])

    case Sidecar.Beads.list(list_opts) do
      {:ok, %{"items" => items}} -> items
      {:error, _reason} -> []
    end
  end
end
