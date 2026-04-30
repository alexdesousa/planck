defmodule Planck.AI.LLMDB do
  @moduledoc false

  require Logger

  alias Planck.AI.Model

  @loaded_key {__MODULE__, :loaded}

  @doc """
  Returns all `Planck.AI.Model` structs for the given LLMDB provider atom.

  Lazily loads the LLMDB snapshot on first call. Returns `[]` on any failure.
  """
  @spec models(atom()) :: [Model.t()]
  def models(provider) do
    unless :persistent_term.get(@loaded_key, false) do
      case LLMDB.load() do
        {:ok, _} ->
          :persistent_term.put(@loaded_key, true)

        {:error, reason} ->
          Logger.warning("[Planck.AI] LLMDB failed to load: #{inspect(reason)}")
      end
    end

    provider
    |> LLMDB.models()
    |> Enum.map(&translate/1)
  end

  # Translates an LLMDB.Model into a Planck.AI.Model.
  defp translate(m) do
    %Model{
      id: m.id,
      name: m.name || m.id,
      provider: m.provider,
      context_window: context_window(m),
      max_tokens: max_tokens(m),
      supports_thinking: supports_thinking(m),
      input_types: input_types(m),
      cost: cost(m)
    }
  end

  defp context_window(%{limits: %{context: ctx}}) when is_integer(ctx) and ctx > 0, do: ctx
  defp context_window(_), do: 4_096

  defp max_tokens(%{limits: %{output: out}}) when is_integer(out) and out > 0, do: out
  defp max_tokens(_), do: 2_048

  defp supports_thinking(%{capabilities: %{reasoning: %{enabled: true}}}), do: true
  defp supports_thinking(_), do: false

  defp input_types(%{modalities: %{input: inputs}}) when is_list(inputs) do
    filtered = Enum.filter(inputs, &(&1 in [:text, :image]))
    if filtered == [], do: [:text], else: filtered
  end

  defp input_types(_), do: [:text]

  defp cost(%{cost: cost}) when is_map(cost) do
    %{
      input: Map.get(cost, :input) || 0.0,
      output: Map.get(cost, :output) || 0.0,
      cache_read: Map.get(cost, :cache_read) || 0.0,
      cache_write: Map.get(cost, :cache_write) || 0.0
    }
  end

  defp cost(_), do: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0}
end
