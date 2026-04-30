defmodule Planck.Agent.Compactor do
  @moduledoc """
  Behaviour and default implementation for context compaction in `Planck.Agent`.

  ## Behaviour

  Implement this behaviour to supply a custom compaction strategy:

      defmodule MyApp.Compactor do
        @behaviour Planck.Agent.Compactor

        @impl true
        def compact(messages) do
          summary = summarise(messages)
          kept    = Enum.take(messages, -5)
          {:compact, summary, kept}
        end

        defp summarise(messages), do: ...
      end

  Load the module from a `.exs` file:

      {:ok, on_compact} = Planck.Agent.Compactor.load("my_compactor.exs")

  ## Default compactor

  `build/2` returns a ready-to-use `on_compact` function backed by the LLM:

      on_compact = Planck.Agent.Compactor.build(model, ratio: 0.8)

  ## Compaction strategy

  When triggered, the oldest messages (everything except the last `keep_recent`
  messages) are summarized into a single `{:custom, :summary}` message. The
  summary prompt instructs the LLM to:

  - Describe completed work briefly
  - State the current active goal and latest requests in full detail
  - Retain key facts, file paths, decisions, and constraints still relevant

  On failure the original message list is returned unchanged.
  """

  alias Planck.Agent.{AIBehaviour, Message}
  alias Planck.AI.{Context, Model}

  @callback compact(messages :: [Message.t()]) ::
              {:compact, summary :: Message.t(), kept :: [Message.t()]} | :skip

  @default_ratio 0.8
  @default_keep_recent 10

  @typedoc """
  Options accepted by `build/2`.

  - `:ratio` — fraction of `model.context_window` that triggers compaction
    (default `#{@default_ratio}`)
  - `:keep_recent` — number of recent messages to keep verbatim, outside the
    summary (default `#{@default_keep_recent}`)
  """
  @type opts :: [ratio: float(), keep_recent: pos_integer()]

  @summary_prompt """
  Summarize the conversation below to reduce context length.
  Your summary must:
  - Describe completed work and resolved decisions briefly
  - State clearly what is currently being worked on and the most recent requests
  - Preserve any key facts, file paths, decisions, or constraints still relevant
  - Be written as context for an AI agent continuing this conversation

  Prioritize recency — the active task and latest requests take priority over earlier history.
  """

  @doc """
  Load a custom compactor from a `.exs` file.

  The file must define a module that implements the `Planck.Agent.Compactor`
  behaviour (i.e. exports `compact/1`). Returns `{:error, reason}` if the file
  is missing, fails to compile, or contains no module with a `compact/1`
  function.
  """
  @spec load(Path.t()) :: {:ok, ([Message.t()] -> term())} | {:error, String.t()}
  def load(path) do
    expanded = Path.expand(path)
    modules = Code.compile_file(expanded)

    case Enum.find(modules, fn {mod, _binary} -> function_exported?(mod, :compact, 1) end) do
      {mod, _binary} -> {:ok, &mod.compact/1}
      nil -> {:error, "no module implementing Planck.Agent.Compactor found in #{path}"}
    end
  rescue
    e -> {:error, "failed to load compactor #{path}: #{Exception.message(e)}"}
  end

  @doc """
  Build an `on_compact` function for the given model.

  The returned function estimates the token count of the message list and
  returns `:skip` when below the threshold, or `{:compact, summary_msg, kept}`
  when compaction is triggered.

  - `summary_msg` — a `{:custom, :summary}` `Message` wrapping the LLM summary
  - `kept` — the last `keep_recent` messages that were not summarised

  On LLM failure the function returns `:skip` (no-op).

  ## Examples

      iex> on_compact = Planck.Agent.Compactor.build(model, ratio: 0.75)
      iex> is_function(on_compact, 1)
      true

  """
  @spec build(Model.t(), opts()) ::
          ([Message.t()] -> :skip | {:compact, Message.t(), [Message.t()]})
  def build(%Model{} = model, opts \\ []) do
    ratio = Keyword.get(opts, :ratio, @default_ratio)
    keep_recent = Keyword.get(opts, :keep_recent, @default_keep_recent)
    threshold = trunc(model.context_window * ratio)

    fn messages ->
      if estimate_tokens(messages) >= threshold do
        compact(messages, model, keep_recent)
      else
        :skip
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec estimate_tokens([Message.t()]) :: non_neg_integer()
  defp estimate_tokens(messages) do
    messages
    |> Enum.flat_map(& &1.content)
    |> Enum.reduce(0, fn
      {:text, text}, acc -> acc + div(String.length(text), 4)
      {:thinking, text}, acc -> acc + div(String.length(text), 4)
      _other, acc -> acc
    end)
  end

  @spec compact([Message.t()], Model.t(), pos_integer()) ::
          :skip | {:compact, Message.t(), [Message.t()]}
  defp compact(messages, model, keep_recent) do
    {old, kept} = Enum.split(messages, -keep_recent)

    case {old, summarize(old, model)} do
      {[], _} ->
        :skip

      {_, {:ok, text}} ->
        summary_msg = Message.new({:custom, :summary}, [{:text, text}])
        {:compact, summary_msg, kept}

      {_, {:error, _}} ->
        :skip
    end
  end

  @spec summarize([Message.t()], Model.t()) :: {:ok, String.t()} | {:error, term()}
  defp summarize(messages, model) do
    history = format_history(messages)

    context = %Context{
      system: @summary_prompt,
      messages: [%Planck.AI.Message{role: :user, content: [{:text, history}]}],
      tools: []
    }

    result =
      AIBehaviour.client().stream(model, context, [])
      |> Enum.reduce({:ok, ""}, fn
        {:text_delta, text}, {:ok, acc} -> {:ok, acc <> text}
        {:error, reason}, _acc -> {:error, reason}
        _other, acc -> acc
      end)

    case result do
      {:ok, ""} -> {:error, :empty_response}
      {:ok, text} -> {:ok, text}
      {:error, _} = error -> error
    end
  end

  @spec format_history([Message.t()]) :: String.t()
  defp format_history(messages) do
    messages
    |> Enum.map_join("\n\n", fn %Message{role: role, content: content} ->
      label = format_role(role)
      text = extract_text(content)
      "#{label}: #{text}"
    end)
  end

  @spec format_role(Message.role()) :: String.t()
  defp format_role(:user), do: "User"
  defp format_role(:assistant), do: "Assistant"
  defp format_role(:tool_result), do: "Tool result"
  defp format_role({:custom, kind}), do: kind |> Atom.to_string() |> String.capitalize()

  @spec extract_text([Planck.AI.Message.content_part()]) :: String.t()
  defp extract_text(content) do
    Enum.reduce(content, "", fn
      {:text, text}, acc -> acc <> text
      {:thinking, text}, acc -> acc <> text
      {:tool_result, _id, value}, acc -> acc <> value
      _other, acc -> acc
    end)
  end
end
