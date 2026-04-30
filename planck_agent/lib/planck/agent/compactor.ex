defmodule Planck.Agent.Compactor do
  @moduledoc """
  Behaviour and default implementation for context compaction in `Planck.Agent`.

  ## Behaviour

  Use `use Planck.Agent.Compactor` to implement a custom compaction strategy.
  The only required callback is `compact/2`; `compact_timeout/0` has a default
  implementation of #{120_000} ms.

      defmodule MySidecar.Compactors.Builder do
        use Planck.Agent.Compactor

        @impl true
        def compact(_model, messages) do
          summary = Message.new({:custom, :summary}, [{:text, summarise(messages)}])
          kept    = Enum.take(messages, -5)
          {:compact, summary, kept}
        end

        # Optional — override to declare a custom RPC timeout.
        @impl true
        def compact_timeout, do: 60_000
      end

  ## Building an on_compact function

  `build/2` is the single entry point for both the local LLM-based compactor and
  remote sidecar compactors. When `sidecar_node:` and `compactor:` options are
  absent it runs locally; when both are present it calls the remote module via
  `:rpc.call/5` and falls back to the local compactor if the RPC fails.

      # Local (default):
      on_compact = Planck.Agent.Compactor.build(model)

      # Remote sidecar:
      on_compact = Planck.Agent.Compactor.build(model,
        sidecar_node: :planck_sidecar@localhost,
        compactor:    "MySidecar.Compactors.Builder"
        # The string is converted to the atom :"Elixir.MySidecar.Compactors.Builder"
        # before the RPC call. Always use the bare Elixir module name (no "Elixir." prefix).
      )

  Both return a `fn messages ->` closure of arity 1, as expected by `Planck.Agent`.

  ## Compaction strategy (local default)

  When triggered, the oldest messages (everything except the last `keep_recent`
  messages) are summarised into a single `{:custom, :summary}` message. On LLM
  failure the local compactor falls back to the original message list unchanged
  (`:skip`). On remote failure the local compactor is used as the fallback.
  """

  require Logger

  alias Planck.Agent.{AIBehaviour, Message}
  alias Planck.AI.{Context, Model}

  @default_compact_timeout_ms 120_000

  @doc """
  Compact the message list.

  Return `{:compact, summary_msg, kept}` to replace older messages with a summary,
  or `:skip` to leave the list unchanged.

  - `summary_msg` — a `{:custom, :summary}` `Message` containing the summary text
  - `kept` — recent messages retained verbatim after the summary
  """
  @callback compact(model :: Model.t(), messages :: [Message.t()]) ::
              {:compact, summary :: Message.t(), kept :: [Message.t()]} | :skip

  @doc """
  RPC call timeout in milliseconds when this compactor is invoked remotely.

  Defaults to #{@default_compact_timeout_ms} ms. Override to declare a custom
  expected latency for the compactor — the module knows its own logic better
  than any caller default.
  """
  @callback compact_timeout() :: pos_integer()

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour unquote(__MODULE__)

      @impl unquote(__MODULE__)
      def compact_timeout, do: unquote(__MODULE__).default_compact_timeout()

      defoverridable compact_timeout: 0
    end
  end

  @doc "Default RPC timeout used when a compactor module omits `compact_timeout/0`."
  @spec default_compact_timeout() :: pos_integer()
  def default_compact_timeout, do: @default_compact_timeout_ms

  @default_ratio 0.8
  @default_keep_recent 10

  @typedoc """
  Options accepted by `build/2`.

  - `:ratio` — fraction of `model.context_window` that triggers compaction
    (default `#{@default_ratio}`)
  - `:keep_recent` — number of recent messages to keep verbatim (default `#{@default_keep_recent}`)
  - `:sidecar_node` — node name of a connected sidecar (enables remote compaction)
  - `:compactor` — fully-qualified module name string in the sidecar,
    e.g. `"MySidecar.Compactors.Builder"`. Required when `:sidecar_node` is set.
  """
  @type opts :: [
          ratio: float(),
          keep_recent: pos_integer(),
          sidecar_node: atom() | nil,
          compactor: String.t() | nil
        ]

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
  Build an `on_compact` function for the given model.

  Returns a `fn messages ->` closure of arity 1. When remote options are provided
  (`sidecar_node:` and `compactor:`), the closure calls the remote module via RPC
  and falls back to the local LLM-based compactor if the call fails.

  ## Examples

      # Local:
      on_compact = Planck.Agent.Compactor.build(model, ratio: 0.75)

      # Remote sidecar with local fallback:
      on_compact = Planck.Agent.Compactor.build(model,
        sidecar_node: :planck_sidecar@localhost,
        compactor: "MySidecar.Compactors.Builder"
      )

  """
  @spec build(Model.t(), opts()) ::
          ([Message.t()] -> :skip | {:compact, Message.t(), [Message.t()]})
  def build(%Model{} = model, opts \\ []) do
    local = build_local(model, opts)

    case {Keyword.get(opts, :sidecar_node), Keyword.get(opts, :compactor)} do
      {nil, _} -> local
      {_, nil} -> local
      {node, name} -> build_remote(model, node, name, local)
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec build_local(Model.t(), opts()) ::
          ([Message.t()] -> :skip | {:compact, Message.t(), [Message.t()]})
  defp build_local(model, opts) do
    ratio = Keyword.get(opts, :ratio, @default_ratio)
    keep_recent = Keyword.get(opts, :keep_recent, @default_keep_recent)
    threshold = trunc(model.context_window * ratio)

    fn messages ->
      if estimate_tokens(messages) >= threshold do
        compact_local(messages, model, keep_recent)
      else
        :skip
      end
    end
  end

  @spec build_remote(Model.t(), atom(), String.t(), function()) ::
          ([Message.t()] -> :skip | {:compact, Message.t(), [Message.t()]})
  defp build_remote(model, sidecar_node, compactor_name, local_fallback) do
    module = :"Elixir.#{compactor_name}"
    :rpc.call(sidecar_node, :code, :ensure_loaded, [module], 5_000)
    timeout = remote_compact_timeout(module, sidecar_node)

    fn messages ->
      case :rpc.call(sidecar_node, module, :compact, [model, messages], timeout) do
        {:badrpc, reason} ->
          Logger.warning(
            "[Planck.Agent.Compactor] sidecar RPC failed (#{compactor_name}): #{inspect(reason)}, falling back to local"
          )

          local_fallback.(messages)

        result ->
          result
      end
    end
  end

  @spec remote_compact_timeout(module(), atom()) :: pos_integer()
  defp remote_compact_timeout(module, sidecar_node) do
    case :rpc.call(sidecar_node, module, :compact_timeout, [], 5_000) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @default_compact_timeout_ms
    end
  end

  @spec compact_local([Message.t()], Model.t(), pos_integer()) ::
          :skip | {:compact, Message.t(), [Message.t()]}
  defp compact_local(messages, model, keep_recent) do
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
