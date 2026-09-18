defmodule Sidecar.Beads do
  @moduledoc """
  Thin HTTP client for the beads instance configured in `Sidecar.Config`.

  Talks to the `beads` compose service over the internal Docker network
  (`bd serve`'s HTTP API), not the `bd` CLI directly. Every request/response
  shape below is read from beads' own OpenAPI spec
  (`internal/httpapi/spec/openapi.v0.yaml` in its source), not guessed —
  several of them (`ready/1` being a separate endpoint from `list/1`,
  `claim/2`'s body shape, `delete/2`'s HTTP method) contradict what a
  surface reading of the CLI's own `--help` output would suggest.

  One beads instance is shared by every agent and session in a Planck
  installation — not per-project, not per-session.

  ## The `:client` option

  Every function here reads `Sidecar.Config.beads_url!/0` and
  `beads_token!/0` by default. Passing `client: %{url: ..., token: ...}` in
  a function's opts/params overrides both for that one call, without
  touching `Sidecar.Config` (and so without the global `Application.env`
  mutation that forces a test using it to run `async: false`). This exists
  for tests, not production traffic — a real deployment has exactly one
  beads instance and has no reason to override it per call.
  """

  @typedoc "Overrides `Sidecar.Config`'s beads URL/token for one call."
  @type client :: %{url: String.t(), token: String.t()}

  @doc """
  List beads — the widget's board (open + in_progress columns by default).
  Not for `bd_ready`; see `ready/1`, a different endpoint with different
  semantics. `params` accepts `status`/`limit`/`cursor`/`sort`/`all` as
  documented by the API (plus `:client`, see the moduledoc) — the default
  excludes closed status, pass `status: "closed"` for the done list.
  """
  @spec list(keyword()) :: {:ok, map()} | {:error, term()}
  def list(params \\ []) do
    {client, query} = extract_client(params)
    get(client, "/v0/beads/issues", query)
  end

  @doc """
  Beads with no open blockers — restricted to `status=open` AND no
  unresolved blockers. A DIFFERENT endpoint from `list/1`, not a status
  filter on it: an open-but-blocked issue passes a naive `status=open`
  filter but never appears here. This is what `bd_ready` (the LLM tool)
  calls, matching `bd ready --json` exactly. `params` also accepts
  `:client`, see the moduledoc.
  """
  @spec ready(keyword()) :: {:ok, map()} | {:error, term()}
  def ready(params \\ []) do
    {client, query} = extract_client(params)
    get(client, "/v0/beads/ready", query)
  end

  @doc """
  Create a bead. `issue_type` is technically optional in the schema but an
  omitted one is refused by workspace validation on every shipped
  workspace — always send it.

  `opts[:description]`/`opts[:priority]` (0 = P0/critical through 4) are
  included only when given — `CreateIssueRequest` treats an absent member as
  "use the workspace default", not the same thing as an explicit `null` for
  every field (`estimated_minutes`/`due_at` are documented as refusing
  `null` outright as a redundant spelling of omission), so sending `nil`
  isn't a safe stand-in for leaving a key out entirely. `opts` also accepts
  `:client`, see the moduledoc.
  """
  @spec create(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(title, actor, opts \\ []) do
    {client, opts} = extract_client(opts)

    body =
      %{title: title, actor: actor, issue_type: "task"}
      |> maybe_put(:description, opts[:description])
      |> maybe_put(:priority, opts[:priority])

    post(client, "/v0/beads/issues", body)
  end

  @doc """
  Fetch one bead by its exact id — not a list filter, the single-issue
  read. Includes whatever the human has since edited (description,
  priority, status, ...), which matters for an agent that claimed a bead
  earlier in a long-running session and has no other way to notice a
  description changed since — `ready/1` no longer lists it once claimed,
  and `claim/2`'s own response is a one-time snapshot from claim time.
  `opts` accepts `:client`, see the moduledoc.
  """
  @spec fetch(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch(id, opts \\ []) do
    {client, _opts} = extract_client(opts)
    get(client, "/v0/beads/issues/#{id}", [])
  end

  @doc """
  Claim a bead for `actor`. Body is `{actor}` ONLY —
  `additionalProperties: false`, so a redundant `assignee` field would be
  refused outright as an unknown body member. Real compare-and-set
  semantics server-side (200 `already_claimed: true` on an idempotent
  re-claim by the same actor; 409 if someone else holds it or it's not
  claimable) — no client-side race guard needed. `opts` accepts `:client`,
  see the moduledoc.
  """
  @spec claim(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def claim(id, actor, opts \\ []) do
    {client, _opts} = extract_client(opts)
    post(client, "/v0/beads/issues/#{id}:claim", %{actor: actor})
  end

  @doc """
  Close (mark done) a bead. Idempotent re-close (200, `already_closed: true`)
  writes neither `reason` nor `session` — first close wins. `opts` accepts
  `:reason` (defaults to `nil`) and `:client`, see the moduledoc.
  """
  @spec close(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def close(id, actor, opts \\ []) do
    {client, opts} = extract_client(opts)
    post(client, "/v0/beads/issues/#{id}:close", %{actor: actor, reason: opts[:reason]})
  end

  @doc """
  Delete beads by id. A collection-level custom method
  (`POST .../issues:delete`), NOT `DELETE .../issues/{id}`. Refuses (400)
  if a named bead has a dependent outside the request unless cascade/force
  is set — not needed for a single-id case. `opts` accepts `:client`, see
  the moduledoc.
  """
  @spec delete([String.t()], String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def delete(ids, actor \\ nil, opts \\ []) when is_list(ids) do
    {client, _opts} = extract_client(opts)
    post(client, "/v0/beads/issues:delete", %{ids: ids, actor: actor})
  end

  @doc """
  Tells every open beads board widget to re-render. Called by every mutating
  tool (`bd_claim`/`bd_create`/`bd_delete`/`bd_done`) and by the widget's own
  action handler, after their write succeeds — a bead claimed from the LLM
  side should show up on a human's already-open board without them
  re-opening it, and vice versa.

  Renders through Sidecar.Widgets.Beads's `render/2`, forwarding `opts` to
  it — so `:client` (see the moduledoc) reaches the board's own re-fetch
  too, not just whichever write triggered this call. Its `render/1`, the
  actual `Planck.Agent.Widget` behaviour callback every real dispatch calls,
  is unaffected — a widget's callback shape doesn't grow a second argument
  just because this one test-only path needs to reach past it.

  `opts` also accepts `:instance`, overriding the topic's widget id (default
  `"beads-board"`, matching Sidecar.Widgets.Beads's own `id/0` — real
  dispatch never sets this). Only a test running several of these broadcasts
  concurrently and asserting on them individually needs it, to give each one
  a topic the others can't land a message on.

  Broadcasts on `Planck.Agent.PubSub` — the sidecar starts no PubSub
  process of its own; every subscriber (`Planck.Web.Live.SidecarWidget`, via
  `SessionLive`'s `open_widget`) lives on the connected `planck_headless`/
  `planck_cli` side and already subscribes there, on the same
  `"sidecar:widget:\#{id}"` topic this reaches. The 3-element
  `{:widget_rendered, id, html}` shape matches what `handle_info/2` there
  expects — the widget id rides along because one topic-name PATTERN covers
  every widget kind, not just this one.
  """
  @spec broadcast_refresh(keyword()) :: :ok | {:error, term()}
  def broadcast_refresh(opts \\ []) do
    {instance, render_opts} = Keyword.pop(opts, :instance, "beads-board")

    Phoenix.PubSub.broadcast(
      Planck.Agent.PubSub,
      "sidecar:widget:#{instance}",
      {:widget_rendered, instance, Sidecar.Widgets.Beads.render(nil, render_opts)}
    )
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec extract_client(keyword()) :: {client(), keyword()}
  defp extract_client(opts) do
    case Keyword.pop(opts, :client, nil) do
      {nil, rest} -> {default_client(), rest}
      {client, rest} -> {client, rest}
    end
  end

  @spec default_client() :: client()
  defp default_client do
    %{
      url: Sidecar.Config.beads_url!(),
      token: Sidecar.Config.beads_token!()
    }
  end

  @spec get(client(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defp get(client, path, params) do
    client
    |> url(path)
    |> Req.get(headers: headers(client), params: params)
    |> respond()
  end

  @spec post(client(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  defp post(client, path, body) do
    client
    |> url(path)
    |> Req.post(headers: headers(client), json: body)
    |> respond()
  end

  @spec maybe_put(map(), atom(), term()) :: map()
  defp maybe_put(map, key, value)
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @spec respond({:ok, Req.Response.t()} | {:error, term()}) :: {:ok, map()} | {:error, term()}
  defp respond(result)
  defp respond({:ok, %{status: status, body: body}}) when status in 200..299, do: {:ok, body}
  defp respond({:ok, %{status: status, body: body}}), do: {:error, {status, body}}
  defp respond({:error, reason}), do: {:error, reason}

  @spec url(client(), String.t()) :: String.t()
  defp url(client, path), do: client.url <> path

  @spec headers(client()) :: [{String.t(), String.t()}]
  defp headers(client), do: [{"authorization", "Bearer #{client.token}"}]
end
