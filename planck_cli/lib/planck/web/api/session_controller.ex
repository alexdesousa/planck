defmodule Planck.Web.API.SessionController do
  use Planck.Web, :controller

  plug OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true

  alias OpenApiSpex.Operation
  alias Planck.Agent
  alias Planck.Agent.Session
  alias Planck.Web.API.Schemas

  def open_api_operation(:index),
    do: %Operation{
      tags: ["Sessions"],
      summary: "List sessions",
      description: "Returns all sessions, both active and closed.",
      operationId: "SessionController.index",
      responses: %{200 => Operation.response("Sessions", "application/json", Schemas.SessionList)}
    }

  def open_api_operation(:create),
    do: %Operation{
      tags: ["Sessions"],
      summary: "Start a session",
      operationId: "SessionController.create",
      requestBody:
        Operation.request_body("Session params", "application/json", Schemas.CreateSession),
      responses: %{
        201 => Operation.response("Session", "application/json", Schemas.Session),
        422 => Operation.response("Error", "application/json", Schemas.Error)
      }
    }

  def open_api_operation(:show),
    do: %Operation{
      tags: ["Sessions"],
      summary: "Get session info",
      operationId: "SessionController.show",
      parameters: [Operation.parameter(:id, :path, :string, "Session ID", required: true)],
      responses: %{
        200 => Operation.response("Session", "application/json", Schemas.SessionDetail),
        404 => Operation.response("Error", "application/json", Schemas.Error)
      }
    }

  def open_api_operation(:close),
    do: %Operation{
      tags: ["Sessions"],
      summary: "Close a session",
      description: "Stops all agents. The session file is retained and can be resumed.",
      operationId: "SessionController.close",
      parameters: [Operation.parameter(:id, :path, :string, "Session ID", required: true)],
      responses: %{
        200 => Operation.response("OK", "application/json", Schemas.Ok),
        422 => Operation.response("Error", "application/json", Schemas.Error)
      }
    }

  def open_api_operation(:prompt),
    do: %Operation{
      tags: ["Sessions"],
      summary: "Send a prompt",
      description:
        "Sends a user message to the session orchestrator. " <>
          "Automatically resumes the session if it is closed.",
      operationId: "SessionController.prompt",
      parameters: [Operation.parameter(:id, :path, :string, "Session ID", required: true)],
      requestBody: Operation.request_body("Prompt", "application/json", Schemas.Prompt),
      responses: %{
        200 => Operation.response("OK", "application/json", Schemas.Ok),
        422 => Operation.response("Error", "application/json", Schemas.Error)
      }
    }

  def open_api_operation(:abort),
    do: %Operation{
      tags: ["Sessions"],
      summary: "Abort current turn",
      description: "Aborts the current turn for all agents in the session.",
      operationId: "SessionController.abort",
      parameters: [Operation.parameter(:id, :path, :string, "Session ID", required: true)],
      responses: %{
        200 => Operation.response("OK", "application/json", Schemas.Ok),
        404 => Operation.response("Error", "application/json", Schemas.Error)
      }
    }

  # ---------------------------------------------------------------------------
  # Actions
  # ---------------------------------------------------------------------------

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    sessions =
      Headless.list_sessions()
      |> Enum.map(&format_session/1)

    json(conn, sessions)
  end

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    body = conn.body_params
    opts = []
    opts = if body.template, do: [{:template, body.template} | opts], else: opts
    opts = if body.name, do: [{:name, body.name} | opts], else: opts

    case Headless.start_session(opts) do
      {:ok, session_id} ->
        {:ok, meta} = Session.get_metadata(session_id)

        conn
        |> put_status(201)
        |> json(%{
          id: session_id,
          name: meta["session_name"],
          status: "active",
          team: meta["team_alias"]
        })

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{id: session_id}) do
    case session_detail(session_id) do
      {:ok, detail} -> json(conn, detail)
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Session not found"})
    end
  end

  @spec close(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def close(conn, %{id: session_id}) do
    case Headless.close_session(session_id) do
      :ok -> json(conn, %{ok: true})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  @spec prompt(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def prompt(conn, params)

  def prompt(conn, %{id: session_id}) do
    text = conn.body_params.text

    with :ok <- ensure_active(session_id),
         :ok <- Headless.prompt(session_id, text) do
      json(conn, %{ok: true})
    else
      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{error: inspect(reason)})
    end
  end

  @spec abort(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def abort(conn, params)

  def abort(conn, %{id: session_id}) do
    case Session.get_metadata(session_id) do
      {:ok, meta} ->
        abort_team(meta["team_id"])
        json(conn, %{ok: true})

      {:error, _} ->
        conn
        |> put_status(404)
        |> json(%{error: "Session not found"})
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec session_detail(String.t()) :: {:ok, map()} | {:error, :not_found}
  defp session_detail(session_id)

  defp session_detail(session_id) when is_binary(session_id) do
    with {:error, _} <- Session.get_metadata(session_id),
         sessions = Headless.list_sessions(),
         %{name: name} <- Enum.find(sessions, &(&1.session_id == session_id)) do
      {:ok, %{id: session_id, name: name, status: "closed", team: nil, agents: []}}
    else
      {:ok, meta} ->
        {:ok,
         %{
           id: session_id,
           name: meta["session_name"],
           status: "active",
           team: meta["team_alias"],
           agents: agents_for_team(meta["team_id"])
         }}

      nil ->
        {:error, :not_found}
    end
  end

  @spec format_session(%{session_id: String.t(), name: String.t(), active: boolean()}) ::
          %{id: String.t(), name: String.t(), status: String.t()}
  defp format_session(session)

  defp format_session(%{session_id: id, name: name, active: active})
       when is_binary(id) and is_binary(name) and is_boolean(active) do
    %{id: id, name: name, status: if(active, do: "active", else: "closed")}
  end

  @spec ensure_active(String.t()) :: :ok | {:error, term()}
  defp ensure_active(session_id)

  defp ensure_active(session_id) when is_binary(session_id) do
    with {:error, :not_found} <- Session.whereis(session_id),
         {:ok, _} <- Headless.resume_session(session_id) do
      :ok
    else
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec abort_team(String.t() | nil) :: :ok
  defp abort_team(team_id)

  defp abort_team(team_id) when is_binary(team_id) do
    team_id
    |> agents_for_team()
    |> Enum.each(&abort_agent/1)
  end

  defp abort_team(nil) do
    :ok
  end

  @spec abort_agent(agent) :: :ok
        when agent: %{:id => String.t(), optional(atom()) => any()}
  defp abort_agent(agent)

  defp abort_agent(%{id: agent_id}) do
    case Agent.whereis(agent_id) do
      {:ok, pid} -> Agent.abort(pid)
      _ -> :ok
    end
  end

  @spec agents_for_team(String.t() | nil) :: [map()]
  defp agents_for_team(team_id)

  defp agents_for_team(team_id) when is_binary(team_id) do
    Planck.Agent.Registry
    |> Registry.lookup({team_id, :member})
    |> Enum.map(fn {pid, _} ->
      info = Agent.get_info(pid)
      %{id: info.id, name: info.name, type: info.type, status: info.status}
    end)
  end

  defp agents_for_team(nil) do
    []
  end
end
