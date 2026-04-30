defmodule Planck.AI.Stream do
  @moduledoc """
  Streaming event types and normalization from `req_llm` chunks.

  `req_llm` emits `%ReqLLM.StreamChunk{}` structs with a `:type` field.
  `from_req_llm/1` maps each chunk type to the canonical event tuples consumed
  by `Planck.Agent` and callers of `Planck.AI.stream/3`.

  Tool call arguments arrive as JSON fragments spread across multiple `:meta`
  chunks. This module buffers the fragments and emits a single assembled
  `{:tool_call_complete, ...}` per tool call when the stream finishes.

  Exceptions raised during stream consumption (e.g. `ReqLLM.Error.API.Stream`
  on HTTP errors) are caught and emitted as `{:error, exception}` events,
  halting the stream gracefully.

  ## Event types

  - `{:text_delta, text}` — a chunk of assistant text
  - `{:thinking_delta, text}` — a chunk of extended thinking / reasoning
  - `{:tool_call_complete, %{id, name, args}}` — a fully assembled tool call
  - `{:done, %{stop_reason, usage}}` — stream finished; includes token usage
  - `{:error, reason}` — an error occurred during streaming
  """

  @type tool_call :: %{
          id: String.t(),
          name: String.t(),
          args: map()
        }

  @type usage :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer()
        }

  @type done :: %{
          stop_reason: atom(),
          usage: usage()
        }

  @type t ::
          {:text_delta, String.t()}
          | {:thinking_delta, String.t()}
          | {:tool_call_complete, tool_call()}
          | {:done, done()}
          | {:error, term()}

  @doc """
  Converts a stream of `ReqLLM.StreamChunk` structs into event tuples.

  ## Examples

      iex> chunks = [
      ...>   %{type: :content, text: "Hello"},
      ...>   %{type: :meta, metadata: %{finish_reason: :stop, usage: %{input_tokens: 10, output_tokens: 5}}}
      ...> ]
      iex> chunks |> Planck.AI.Stream.from_req_llm() |> Enum.to_list()
      [{:text_delta, "Hello"}, {:done, %{stop_reason: :stop, usage: %{input_tokens: 10, output_tokens: 5}}}]

  """
  @spec from_req_llm(Enumerable.t()) :: Enumerable.t(t())
  def from_req_llm(chunks) do
    Stream.resource(
      fn -> {pull(chunks), %{calls: %{}, fragments: %{}}} end,
      &emit/1,
      fn _ -> :ok end
    )
  end

  # --- Private ---
  #
  # How one-at-a-time pulling works
  # --------------------------------
  # Stream.resource drives everything. Its `next_fun` (`emit/1`) is called once
  # per consumer demand and must return early — if we let Enumerable.reduce run
  # to completion over the whole upstream, we'd lose all incrementality.
  #
  # The trick is `suspend_reducer/2`, which immediately returns `{:suspend, el}`
  # for every element. This causes Enumerable.reduce to pause after the first
  # element and return:
  #
  #   {:suspended, element, continuation}
  #
  # where `continuation` is a closure over the remaining elements. `step_result`
  # converts that into `{:item, element, continuation}` so `emit` can process
  # one chunk and store the continuation as the next state.
  #
  # The next call to `emit` resumes by calling `pull(continuation)`, which
  # advances by one more element. When the upstream is exhausted, reduce returns
  # `{:done, _}` instead of `{:suspended, ...}`, which becomes `:done` —
  # signalling `emit` to halt the stream.
  #
  # Importantly, `pull` is synchronous: if the upstream is an HTTP stream, it
  # blocks until the next chunk arrives over the network. So even if the
  # consumer is `Enum.to_list` (which is eager), it can't race ahead — it waits
  # on each `pull` just like a lazy consumer would.
  #
  # Continuation arity
  # ------------------
  # List/Stream enumerables produce arity-1 continuations (the reducer is
  # already captured in the closure). Stream.resource-based enumerables produce
  # arity-2 continuations and require the reducer to be passed back in on each
  # call. The two `pull/1` function clauses handle each case.

  defp emit({:done, _tool_acc}), do: {:halt, :done}
  defp emit({{:error, reason}, _tool_acc}), do: {[{:error, reason}], {:done, %{}}}

  defp emit({{:item, chunk, cont}, tool_acc}) do
    {events, new_acc} = process_chunk(chunk, tool_acc)
    {events, {pull(cont), new_acc}}
  end

  # Tool call identity chunk: buffer name/id by index, emit nothing yet.
  defp process_chunk(%{type: :tool_call, name: name} = chunk, acc) do
    index = (chunk.metadata && chunk.metadata[:index]) || 0
    id = (chunk.metadata && chunk.metadata[:id]) || ""
    {[], %{acc | calls: Map.put(acc.calls, index, {id, name})}}
  end

  # Argument fragment: accumulate JSON string by index, emit nothing yet.
  defp process_chunk(
         %{type: :meta, metadata: %{tool_call_args: %{index: index, fragment: frag}}},
         acc
       ) do
    existing = Map.get(acc.fragments, index, [])
    {[], %{acc | fragments: Map.put(acc.fragments, index, [existing | [frag]])}}
  end

  # Final meta chunk: emit assembled tool calls then done.
  defp process_chunk(%{type: :meta, metadata: metadata}, acc) do
    tool_events = assemble_tool_calls(acc)
    stop_reason = Map.get(metadata, :finish_reason, :stop)
    usage = Map.get(metadata, :usage, %{input_tokens: 0, output_tokens: 0})

    {tool_events ++ [{:done, %{stop_reason: stop_reason, usage: usage}}],
     %{calls: %{}, fragments: %{}}}
  end

  # All other chunk types (text, thinking, unknown).
  defp process_chunk(chunk, acc) do
    {[normalize_chunk(chunk)], acc}
  end

  defp assemble_tool_calls(%{calls: calls}) when calls == %{}, do: []

  defp assemble_tool_calls(%{calls: calls, fragments: fragments}) do
    calls
    |> Enum.sort_by(fn {index, _} -> index end)
    |> Enum.map(fn {index, {id, name}} ->
      {:tool_call_complete, %{id: id, name: name, args: decode_args(fragments, index)}}
    end)
  end

  defp decode_args(fragments, index) do
    case Map.get(fragments, index) do
      nil -> %{}
      frags -> frags |> IO.iodata_to_binary() |> ensure_object() |> parse_json()
    end
  end

  defp ensure_object("{" <> _ = json), do: json
  defp ensure_object(json), do: "{" <> json

  defp parse_json(json) do
    case Jason.decode(json) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  # Arity-1 continuations: returned by list and %Stream{} enumerables.
  defp pull(cont) when is_function(cont, 1) do
    cont.({:cont, nil}) |> step_result()
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # Arity-2 continuations: returned by Stream.resource, which passes both the
  # accumulator AND the reducer through the continuation so it can resume
  # enumeration with the same reducer on the next call.
  defp pull(cont) when is_function(cont, 2) do
    cont.({:cont, nil}, &suspend_reducer/2) |> step_result()
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # Initial call: start reducing the upstream enumerable one element at a time.
  defp pull(enum) do
    Enumerable.reduce(enum, {:cont, nil}, &suspend_reducer/2) |> step_result()
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp step_result({:suspended, chunk, cont}), do: {:item, chunk, cont}
  defp step_result({:done, _}), do: :done
  defp step_result({:halted, _}), do: :done

  defp suspend_reducer(el, _acc), do: {:suspend, el}

  defp normalize_chunk(%{type: :content, text: text}), do: {:text_delta, text}
  defp normalize_chunk(%{type: :thinking, text: text}), do: {:thinking_delta, text}
  defp normalize_chunk(chunk), do: {:error, {:unknown_chunk, chunk}}
end
