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
  """

  @doc """
  List beads — the widget's board (open + in_progress columns by default).
  Not for `bd_ready`; see `ready/1`, a different endpoint with different
  semantics. `params` accepts `status`/`limit`/`cursor`/`sort` as documented
  by the API — the default excludes closed status, pass `status: "closed"`
  for the done list.
  """
  @spec list(keyword()) :: {:ok, map()} | {:error, term()}
  def list(params \\ []), do: get("/v0/beads/issues", params)

  @doc """
  Beads with no open blockers — restricted to `status=open` AND no
  unresolved blockers. A DIFFERENT endpoint from `list/1`, not a status
  filter on it: an open-but-blocked issue passes a naive `status=open`
  filter but never appears here. This is what `bd_ready` (the LLM tool)
  calls, matching `bd ready --json` exactly.
  """
  @spec ready(keyword()) :: {:ok, map()} | {:error, term()}
  def ready(params \\ []), do: get("/v0/beads/ready", params)

  @doc """
  Create a bead. `issue_type` is technically optional in the schema but an
  omitted one is refused by workspace validation on every shipped
  workspace — always send it.

  `opts[:description]`/`opts[:priority]` (0 = P0/critical through 4) are
  included only when given — `CreateIssueRequest` treats an absent member as
  "use the workspace default", not the same thing as an explicit `null` for
  every field (`estimated_minutes`/`due_at` are documented as refusing
  `null` outright as a redundant spelling of omission), so sending `nil`
  isn't a safe stand-in for leaving a key out entirely.
  """
  @spec create(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(title, actor, opts \\ []) do
    body =
      %{title: title, actor: actor, issue_type: "task"}
      |> maybe_put(:description, opts[:description])
      |> maybe_put(:priority, opts[:priority])

    post("/v0/beads/issues", body)
  end

  @doc """
  Fetch one bead by its exact id — not a list filter, the single-issue
  read. Includes whatever the human has since edited (description,
  priority, status, ...), which matters for an agent that claimed a bead
  earlier in a long-running session and has no other way to notice a
  description changed since — `ready/1` no longer lists it once claimed,
  and `claim/2`'s own response is a one-time snapshot from claim time.
  """
  @spec fetch(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch(id), do: get("/v0/beads/issues/#{id}", [])

  @doc """
  Claim a bead for `actor`. Body is `{actor}` ONLY —
  `additionalProperties: false`, so a redundant `assignee` field would be
  refused outright as an unknown body member. Real compare-and-set
  semantics server-side (200 `already_claimed: true` on an idempotent
  re-claim by the same actor; 409 if someone else holds it or it's not
  claimable) — no client-side race guard needed.
  """
  @spec claim(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def claim(id, actor), do: post("/v0/beads/issues/#{id}:claim", %{actor: actor})

  @doc """
  Close (mark done) a bead. Idempotent re-close (200, `already_closed: true`)
  writes neither `reason` nor `session` — first close wins.
  """
  @spec close(String.t(), String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def close(id, actor, reason \\ nil) do
    post("/v0/beads/issues/#{id}:close", %{actor: actor, reason: reason})
  end

  @doc """
  Delete beads by id. A collection-level custom method
  (`POST .../issues:delete`), NOT `DELETE .../issues/{id}`. Refuses (400)
  if a named bead has a dependent outside the request unless cascade/force
  is set — not needed for a single-id case.
  """
  @spec delete([String.t()], String.t() | nil) :: {:ok, map()} | {:error, term()}
  def delete(ids, actor \\ nil) when is_list(ids) do
    post("/v0/beads/issues:delete", %{ids: ids, actor: actor})
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defp get(path, params) do
    respond(Req.get(url(path), headers: headers(), params: params))
  end

  @spec post(String.t(), map()) :: {:ok, map()} | {:error, term()}
  defp post(path, body) do
    respond(Req.post(url(path), headers: headers(), json: body))
  end

  @spec maybe_put(map(), atom(), term()) :: map()
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @spec respond({:ok, Req.Response.t()} | {:error, term()}) :: {:ok, map()} | {:error, term()}
  defp respond({:ok, %{status: status, body: body}}) when status in 200..299, do: {:ok, body}
  defp respond({:ok, %{status: status, body: body}}), do: {:error, {status, body}}
  defp respond({:error, reason}), do: {:error, reason}

  @spec url(String.t()) :: String.t()
  defp url(path), do: Sidecar.Config.beads_url!() <> path

  @spec headers() :: [{String.t(), String.t()}]
  defp headers, do: [{"authorization", "Bearer #{Sidecar.Config.beads_token!()}"}]
end
