defmodule Planck.Agent.Hooks.Compactor do
  @moduledoc """
  Behaviour and default implementation for context compaction in `Planck.Agent`.

  ## Behaviour

  Use `use Planck.Agent.Hooks.Compactor` to implement a custom compaction strategy
  in a sidecar. The only required callback is `compact/2`; `compact_timeout/0` has a
  default of #{120_000} ms.

      defmodule MySidecar.Compactors.Builder do
        use Planck.Agent.Hooks.Compactor

        @impl true
        def compact(_model, messages) do
          summary = Message.new({:custom, :summary}, [{:text, summarise(messages)}])
          kept    = Enum.take(messages, -5)
          {:compact, summary, kept}
        end

        @impl true
        def compact_timeout, do: 60_000
      end

  ## Dispatch

  `Planck.Agent` stores the resolved compactor module atom in state and calls
  `compact/4` before every LLM turn:

      Hooks.Compactor.compact(state.compactor, state.model, messages, state.sidecar_node)

  - `module: nil` — uses the built-in local LLM-based compactor.
  - `module` set, `sidecar_node: nil` — calls `module.compact/2` in-process.
  - `module` set, `sidecar_node` set — calls the module on the remote node via RPC;
    falls back to the local LLM-based compactor on `:badrpc`.
  """

  require Logger

  alias Planck.Agent.{AIBehaviour, Message}
  alias Planck.AI.{Context, Model}

  @default_compact_timeout_ms 120_000
  @default_ratio 0.8
  @keep_ratio 0.1

  @doc """
  Compact the message list.

  Return `{:compact, summary_msg, kept}` to replace older messages with a summary,
  or `:skip` to leave the list unchanged.
  """
  @callback compact(model :: Model.t(), messages :: [Message.t()]) ::
              {:compact, summary :: Message.t(), kept :: [Message.t()]} | :skip

  @doc """
  RPC call timeout in milliseconds when this compactor is invoked remotely.

  Defaults to #{@default_compact_timeout_ms} ms.
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

  @doc """
  Dispatch compaction for the given module, model, and messages.

  - `nil` — runs the built-in local LLM-based compactor.
  - module set, `sidecar_node: nil` — calls `module.compact/2` in-process.
  - module set, `sidecar_node` set — calls via RPC with local fallback on failure.

  Returns `:skip` or `{:compact, summary_msg, kept}`.
  """
  @spec compact(module() | nil, Model.t(), [Message.t()], atom() | nil) ::
          :skip | {:compact, Message.t(), [Message.t()]}
  def compact(module, model, messages, sidecar_node)

  def compact(nil, model, messages, _sidecar_node) do
    do_local(model, messages)
  end

  def compact(module, model, messages, nil) do
    module.compact(model, messages)
  end

  def compact(module, model, messages, sidecar_node) do
    :rpc.call(sidecar_node, :code, :ensure_loaded, [module], 5_000)
    timeout = remote_timeout(module, sidecar_node)

    case :rpc.call(sidecar_node, module, :compact, [model, messages], timeout) do
      {:badrpc, reason} ->
        Logger.warning(
          "[Planck.Agent.Hooks.Compactor] RPC failed (#{module}): #{inspect(reason)}, falling back to local"
        )

        do_local(model, messages)

      result ->
        result
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @summary_prompt """
  Summarize the conversation below to reduce context length.
  Your summary must:
  - Describe completed work and resolved decisions briefly
  - State clearly what is currently being worked on and the most recent requests
  - Preserve any key facts, file paths, decisions, or constraints still relevant
  - Be written as context for an AI agent continuing this conversation

  Prioritize recency — the active task and latest requests take priority over earlier history.
  """

  @spec do_local(Model.t(), [Message.t()]) :: :skip | {:compact, Message.t(), [Message.t()]}
  defp do_local(model, messages) do
    threshold = trunc(model.context_window * @default_ratio)

    if Message.estimate_tokens(messages) >= threshold do
      compact_local(messages, model)
    else
      :skip
    end
  end

  @spec compact_local([Message.t()], Model.t()) ::
          :skip | {:compact, Message.t(), [Message.t()]}
  defp compact_local(messages, model) do
    keep_budget = trunc(model.context_window * @keep_ratio)
    {old, kept} = split_by_token_budget(messages, keep_budget)
    to_summarize = Enum.reject(old, &match?(%Message{role: {:custom, :summary}}, &1))

    case {to_summarize, summarize(to_summarize, model)} do
      {[], _} ->
        :skip

      {_, {:ok, text}} ->
        summary_msg = Message.new({:custom, :summary}, [{:text, text}])
        {:compact, summary_msg, kept}

      {_, {:error, _}} ->
        :skip
    end
  end

  # Walk from the tail, accumulating messages until the token budget is exceeded.
  # Always keeps at least the last message even if it alone exceeds the budget.
  @spec split_by_token_budget([Message.t()], non_neg_integer()) ::
          {[Message.t()], [Message.t()]}
  defp split_by_token_budget(messages, budget) do
    {kept, _} =
      messages
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn msg, {kept, total} ->
        cost = Message.estimate_tokens([msg])
        new_total = total + cost

        if new_total <= budget or kept == [] do
          {:cont, {[msg | kept], new_total}}
        else
          {:halt, {kept, total}}
        end
      end)

    Enum.split(messages, length(messages) - length(kept))
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
      |> Enum.reduce({:ok, []}, fn
        {:text_delta, text}, {:ok, acc} -> {:ok, [acc | text]}
        {:error, reason}, _acc -> {:error, reason}
        _other, acc -> acc
      end)

    case result do
      {:ok, []} -> {:error, :empty_response}
      {:ok, iodata} -> {:ok, IO.iodata_to_binary(iodata)}
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
    content
    |> Enum.flat_map(fn
      {:text, text} -> [text]
      {:tool_result, _id, value} -> [value]
      _ -> []
    end)
    |> IO.iodata_to_binary()
  end

  @spec remote_timeout(module(), atom()) :: pos_integer()
  defp remote_timeout(module, sidecar_node) do
    case :rpc.call(sidecar_node, module, :compact_timeout, [], 5_000) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @default_compact_timeout_ms
    end
  end
end
