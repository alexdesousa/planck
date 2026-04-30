defmodule Planck.Web.Live.ChatEntries do
  @moduledoc """
  Pure functions for building displayable chat entries from session rows.

  ## Perspective

  Every chat view has a *perspective* — the agent whose conversation we render.
  Messages are classified as:

  - **left** (respondent): messages the perspective agent produced (text,
    thinking, tool calls).
  - **right** (asker/delegator): messages *addressed to* the perspective agent —
    real user input when viewing the orchestrator, or inter-agent delegations
    from another agent when viewing a worker.

  ## Author

  Each entry carries an `:author` field:

  - `:user` — the human user
  - `{:agent, id, name}` — an agent

  Use `author_label/1` to get the display string.
  """

  @inter_agent_tools ~w(ask_agent delegate_task send_response interrupt_agent)

  @typedoc "Who produced a message — either the human user or a named agent."
  @type author :: :user | {:agent, id :: String.t(), name :: String.t()}

  @typedoc """
  Minimal agent descriptor needed for classification.

  `:type` is required (e.g. `"orchestrator"`, `"worker"`). `:name` is the
  human-readable display name; when absent, type is used as a fallback.
  Additional keys (status, model, cost, etc.) are ignored.
  """
  @type agent_info :: %{
          required(:type) => String.t(),
          optional(:name) => String.t() | nil,
          optional(atom()) => term()
        }

  @typedoc "Map of agent id to its descriptor, as built by `SessionLive.load_agents/1`."
  @type agents :: %{String.t() => agent_info()}

  @typedoc """
  A single persisted message as returned by `Planck.Agent.Session.messages/1`.

  Each row belongs to one agent (`agent_id`) and wraps a `Message` that holds
  the role and content parts. Multiple agents share the same session, so rows
  from different agents are interleaved in insertion order.
  """
  @type row :: %{
          db_id: pos_integer(),
          agent_id: String.t(),
          message: Planck.Agent.Message.t(),
          inserted_at: integer()
        }

  @typedoc """
  Discriminant for `entry()`. Determines which optional keys are present:

  - `:user` — human input; has `:text`
  - `:text` — agent prose response; has `:text`
  - `:thinking` — extended thinking block; has `:text`, `:expanded`
  - `:tool` — tool invocation; has `:tool_id`, `:tool_name`, `:tool_subtitle`,
    `:tool_args`, `:tool_result`, `:tool_error`, `:expanded`
  - `:inter_agent_in` — delegation or question received from another agent;
    has `:text`, `:tool_name`
  - `:error` — agent-level error; has `:text`, `:expanded`
  - `:summary` — context-compaction marker; has `:text`
  - `:agent_response` — a worker's response sent back to the orchestrator; has `:text`, `:expanded`
  """
  @type entry_type ::
          :user
          | :text
          | :thinking
          | :tool
          | :inter_agent_in
          | :error
          | :summary
          | :agent_response

  @typedoc """
  A display-ready map consumed by the chat template.

  The four required keys are always present. Optional keys depend on
  `:type` — see `entry_type()` for the full breakdown.
  """
  @type entry :: %{
          required(:id) => String.t() | pos_integer(),
          required(:type) => entry_type(),
          required(:side) => :left | :right,
          required(:author) => author(),
          optional(:text) => String.t(),
          optional(:streaming) => boolean(),
          optional(:expanded) => boolean(),
          optional(:tool_id) => String.t(),
          optional(:tool_name) => String.t(),
          optional(:tool_subtitle) => String.t() | nil,
          optional(:tool_args) => map(),
          optional(:tool_result) => String.t() | nil,
          optional(:tool_error) => boolean(),
          optional(:timestamp) => DateTime.t() | nil
        }

  # Internal marker produced by content_to_entries/tool_result_markers and
  # consumed by pair_tool_results. Never present in the final [entry()] output.
  @typep tool_result_marker :: %{
           __tool_result__: true,
           tool_id: String.t(),
           result: term()
         }

  # ---------------------------------------------------------------------------
  # Public API — factories
  # ---------------------------------------------------------------------------

  @doc "Build a fresh user-input entry (right side, `:user` author)."
  @spec new_user_entry(String.t()) :: entry()
  def new_user_entry(text) do
    %{
      id: "user-#{:erlang.unique_integer([:positive])}",
      type: :user,
      side: :right,
      author: :user,
      text: text,
      streaming: false,
      timestamp: DateTime.utc_now()
    }
  end

  @doc "Build a streaming text entry for a given agent (left side, `streaming: true`)."
  @spec new_text_entry(author(), String.t(), String.t()) :: entry()
  def new_text_entry(author, text, id) do
    %{
      id: id,
      type: :text,
      side: :left,
      author: author,
      text: text,
      streaming: true,
      timestamp: DateTime.utc_now()
    }
  end

  @doc "Build a streaming thinking entry (left side, `streaming: true`, `expanded: false`)."
  @spec new_thinking_entry(author(), String.t(), String.t()) :: entry()
  def new_thinking_entry(author, text, id) do
    %{
      id: id,
      type: :thinking,
      side: :left,
      author: author,
      text: text,
      streaming: true,
      expanded: false,
      timestamp: DateTime.utc_now()
    }
  end

  @doc "Build a tool entry for when a tool call starts (left side)."
  @spec new_tool_entry(author(), String.t(), String.t(), map()) :: entry()
  def new_tool_entry(author, tool_id, name, args) do
    %{
      id: "tool-#{tool_id}",
      type: :tool,
      side: :left,
      author: author,
      tool_id: tool_id,
      tool_name: name,
      tool_subtitle: tool_subtitle(name, args),
      tool_args: args,
      tool_result: nil,
      tool_error: false,
      expanded: false,
      streaming: false,
      timestamp: DateTime.utc_now()
    }
  end

  @doc "Build an incoming inter-agent delegation/question entry (right side)."
  @spec new_inter_agent_in_entry(author(), String.t(), String.t(), String.t()) :: entry()
  def new_inter_agent_in_entry(author, text, tool_name, id) do
    %{
      id: id,
      type: :inter_agent_in,
      side: :right,
      author: author,
      text: text,
      tool_name: tool_name,
      streaming: false,
      timestamp: DateTime.utc_now()
    }
  end

  @doc "Build an error entry (left side, `expanded: false`)."
  @spec new_error_entry(author(), String.t(), String.t()) :: entry()
  def new_error_entry(author, reason, id) do
    %{
      id: id,
      type: :error,
      side: :left,
      author: author,
      text: reason,
      expanded: false,
      timestamp: DateTime.utc_now()
    }
  end

  @doc "Toggle the `:expanded` field of the entry matching `entry_id`."
  @spec toggle_entry([entry()], String.t()) :: [entry()]
  def toggle_entry(entries, entry_id) do
    Enum.map(entries, fn
      %{id: ^entry_id} = e -> %{e | expanded: !e.expanded}
      e -> e
    end)
  end

  # ---------------------------------------------------------------------------
  # Public API — build from session rows
  # ---------------------------------------------------------------------------

  @doc """
  Build display entries from raw session rows for the given perspective.

  Pass `perspective_id: nil` to auto-detect the orchestrator (main chat).
  """
  @spec build([row()], String.t() | nil, agents()) :: [entry()]
  def build(rows, perspective_id, agents)

  def build(rows, nil, agents) do
    build(rows, find_orchestrator_id(rows, agents), agents)
  end

  def build(rows, perspective_id, agents) do
    rows
    |> Enum.flat_map(
      &classify_row(&1, perspective_id, agents, orchestrator?(perspective_id, agents))
    )
    |> pair_tool_results()
  end

  @doc "Return the display label for an author."
  @spec author_label(author()) :: String.t()
  def author_label(:user), do: "you"
  def author_label({:agent, _id, name}), do: name

  @doc "Pair `:__tool_result__` markers back onto their tool entries."
  @spec pair_tool_results([entry() | tool_result_marker()]) :: [entry()]
  def pair_tool_results(entries) do
    {results, rest} = Enum.split_with(entries, & &1[:__tool_result__])
    results_by_id = Map.new(results, &{&1.tool_id, &1.result})

    Enum.map(rest, fn entry ->
      case Map.get(results_by_id, entry[:tool_id]) do
        nil -> entry
        result -> %{entry | tool_result: format_tool_result(result)}
      end
    end)
  end

  @doc "Short subtitle for a tool call, used in collapsed tool cards."
  @spec tool_subtitle(String.t(), map()) :: String.t() | nil
  def tool_subtitle("bash", %{"command" => cmd}), do: first_line(cmd)
  def tool_subtitle("read", %{"path" => path}), do: path
  def tool_subtitle("write", %{"path" => path}), do: path
  def tool_subtitle("edit", %{"path" => path}), do: path

  def tool_subtitle("ask_agent", args) do
    agent_subtitle(args["name"] || args["type"] || args["id"], args["question"])
  end

  def tool_subtitle("delegate_task", args) do
    agent_subtitle(args["name"] || args["type"] || args["id"], args["task"])
  end

  def tool_subtitle("send_response", %{"response" => r}), do: truncate(r, 80)

  def tool_subtitle("spawn_agent", args) do
    args["name"] || args["type"]
  end

  def tool_subtitle(_, _), do: nil

  @doc "Format a raw tool result value to a display string."
  @spec format_tool_result(term()) :: String.t()
  def format_tool_result({:ok, text}) when is_binary(text), do: text
  def format_tool_result({:error, reason}), do: "Error: #{inspect(reason)}"
  def format_tool_result(result) when is_binary(result), do: result
  def format_tool_result(result), do: inspect(result, pretty: true)

  # ---------------------------------------------------------------------------
  # Orchestrator detection
  # ---------------------------------------------------------------------------

  @spec orchestrator?(String.t() | nil, agents()) :: boolean()
  defp orchestrator?(id, agents)
  defp orchestrator?(nil, _agents), do: false
  defp orchestrator?(id, agents), do: get_in(agents, [id, :type]) == "orchestrator"

  @spec find_orchestrator_id([row()], agents()) :: String.t() | nil
  defp find_orchestrator_id(rows, agents) do
    from_map =
      Enum.find_value(agents, fn {id, agent} ->
        if agent[:type] == "orchestrator", do: id
      end)

    from_rows =
      Enum.find_value(rows, fn %{agent_id: aid, message: msg} ->
        if msg.role == :assistant and
             Enum.any?(msg.content, fn
               {:tool_call, _, name, _} when name in @inter_agent_tools -> true
               _ -> false
             end),
           do: aid
      end)

    from_map || from_rows || List.first(rows, %{})[:agent_id]
  end

  # ---------------------------------------------------------------------------
  # Row classification
  # ---------------------------------------------------------------------------

  @spec classify_row(row(), String.t() | nil, agents(), boolean()) :: [entry()]
  defp classify_row(row, perspective_id, agents, is_orch)

  defp classify_row(%{agent_id: aid, message: msg} = row, aid, agents, is_orch) do
    author = agent_author(aid, agents)

    case msg.role do
      :user when is_orch ->
        [
          %{
            id: msg.id,
            type: :user,
            side: :right,
            author: :user,
            text: extract_text(msg.content),
            streaming: false,
            timestamp: msg.timestamp
          }
        ]

      :user ->
        # Delegated task — skip; already shown as :inter_agent_in from the sender's row
        []

      :assistant ->
        content_to_entries(msg.content, author, msg.id, msg.timestamp)

      :tool_result ->
        tool_result_markers(msg.content)

      {:custom, :summary} ->
        [
          %{
            id: msg.id,
            type: :summary,
            side: :left,
            author: author,
            text: extract_text(msg.content),
            streaming: false,
            timestamp: msg.timestamp
          }
        ]

      {:custom, :agent_response} ->
        entry_author =
          case msg.metadata do
            %{sender_id: sid, sender_name: sname} -> {:agent, sid, sname}
            _ -> :user
          end

        [
          %{
            id: msg.id,
            type: :agent_response,
            side: :right,
            author: entry_author,
            text: extract_text(msg.content),
            streaming: false,
            expanded: false,
            timestamp: msg.timestamp
          }
        ]

      _ ->
        []
    end
  end

  # Row from another agent → look for inter-agent calls targeting the perspective
  defp classify_row(
         %{agent_id: sender_id, message: %{role: :assistant} = msg},
         perspective_id,
         agents,
         _is_orch
       ) do
    sender_author = agent_author(sender_id, agents)
    worker_info = Map.get(agents, perspective_id, %{})
    inter_agent_entries(msg.content, sender_author, worker_info, msg.timestamp)
  end

  defp classify_row(_row, _perspective_id, _agents, _is_orch), do: []

  @spec inter_agent_entries([tuple()], author(), agent_info(), DateTime.t() | nil) :: [entry()]
  defp inter_agent_entries(content, sender_author, worker_info, timestamp) do
    Enum.flat_map(content, fn
      {:tool_call, id, name, args} when name in @inter_agent_tools ->
        if targets_agent?(args, worker_info) do
          [
            %{
              id: "in-#{id}",
              type: :inter_agent_in,
              side: :right,
              author: sender_author,
              text: args["question"] || args["task"] || "",
              tool_name: name,
              streaming: false,
              timestamp: timestamp
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  # ---------------------------------------------------------------------------
  # Content decomposition
  # ---------------------------------------------------------------------------

  @spec content_to_entries([tuple()], author(), String.t(), DateTime.t() | nil) ::
          [entry() | tool_result_marker()]
  defp content_to_entries(content, author, base_id, timestamp) do
    content
    |> Enum.with_index()
    |> Enum.flat_map(fn {part, i} ->
      id = "#{base_id}-#{i}"

      case part do
        {:text, text} when text != "" ->
          [
            %{
              id: id,
              type: :text,
              side: :left,
              author: author,
              text: text,
              streaming: false,
              timestamp: timestamp
            }
          ]

        {:thinking, text} ->
          [
            %{
              id: id,
              type: :thinking,
              side: :left,
              author: author,
              text: text,
              streaming: false,
              expanded: false,
              timestamp: timestamp
            }
          ]

        {:tool_call, tool_id, name, args} ->
          [
            %{
              id: id,
              type: :tool,
              side: :left,
              author: author,
              tool_id: tool_id,
              tool_name: name,
              tool_subtitle: tool_subtitle(name, args),
              tool_args: args,
              tool_result: nil,
              tool_error: false,
              expanded: false,
              streaming: false,
              timestamp: timestamp
            }
          ]

        {:tool_result, tool_id, result} ->
          [%{__tool_result__: true, tool_id: tool_id, result: result}]

        _ ->
          []
      end
    end)
  end

  @spec tool_result_markers([tuple()]) :: [tool_result_marker()]
  defp tool_result_markers(content) do
    Enum.flat_map(content, fn
      {:tool_result, tool_id, result} ->
        [%{__tool_result__: true, tool_id: tool_id, result: result}]

      _ ->
        []
    end)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @spec agent_author(String.t(), agents()) :: author()
  defp agent_author(agent_id, agents) do
    {:agent, agent_id, agent_name(agent_id, agents)}
  end

  @spec agent_name(String.t(), agents()) :: String.t()
  defp agent_name(agent_id, agents) do
    case Map.get(agents, agent_id) do
      nil -> "agent"
      agent -> agent[:name] || agent[:type] || "agent"
    end
  end

  @spec targets_agent?(map(), agent_info()) :: boolean()
  defp targets_agent?(args, worker_info) do
    (worker_info[:type] && args["type"] == worker_info[:type]) ||
      (worker_info[:name] && args["name"] == worker_info[:name])
  end

  @spec extract_text([tuple()]) :: String.t()
  defp extract_text(content) do
    content
    |> Enum.filter(&match?({:text, _}, &1))
    |> Enum.map_join("", fn {:text, t} -> t end)
  end

  @spec agent_subtitle(String.t() | nil, String.t() | nil) :: String.t() | nil
  defp agent_subtitle(nil, content) when is_binary(content), do: truncate(content, 80)
  defp agent_subtitle(target, nil), do: target
  defp agent_subtitle(target, content), do: "#{target} · #{truncate(content, 60)}"

  @spec first_line(String.t()) :: String.t()
  defp first_line(text) do
    text |> String.split("\n") |> List.first("") |> String.trim()
  end

  @spec truncate(String.t(), non_neg_integer()) :: String.t()
  defp truncate(text, max) do
    if String.length(text) > max,
      do: String.slice(text, 0, max) <> "…",
      else: text
  end
end
