defmodule Planck.AI do
  @moduledoc """
  Typed LLM provider abstraction built on top of `req_llm`.

  `Planck.AI` provides a provider-agnostic interface for streaming and completing
  LLM requests. It defines the canonical types (`Model`, `Message`, `Context`, `Tool`)
  and streaming event protocol (`Stream`) consumed by `Planck.Agent`.

  ## Streaming

      model = Planck.AI.Models.Anthropic.all() |> hd()
      context = %Planck.AI.Context{
        system: "You are a helpful assistant.",
        messages: [%Planck.AI.Message{role: :user, content: [{:text, "Hello!"}]}]
      }

      model
      |> Planck.AI.stream(context, temperature: 0.7)
      |> Enum.each(fn
        {:text_delta, text} -> IO.write(text)
        {:done, _} -> IO.puts("")
        _ -> :ok
      end)

  ## Completing

      {:ok, message} = Planck.AI.complete(model, context)

  ## Model catalog

      Planck.AI.list_providers()
      #=> [:anthropic, :openai, :ollama, :llama_cpp]

      Planck.AI.list_models(:anthropic)
      #=> [%Planck.AI.Model{id: "claude-opus-4-5", ...}, ...]

      {:ok, model} = Planck.AI.get_model(:anthropic, "claude-sonnet-4-6")

  """

  alias Planck.AI.{Adapter, Context, Message, Model, Stream}
  alias Planck.AI.Models.{Anthropic, Google, LlamaCpp, Ollama, OpenAI}

  @providers [:anthropic, :openai, :google, :ollama, :llama_cpp]

  @doc """
  Streams a request to the LLM, returning a lazy stream of `StreamEvent` tuples.

  Keyword opts (e.g. `temperature: 0.7`, `max_tokens: 2048`) are forwarded
  directly to `req_llm`, which handles per-provider parameter translation.

  ## Examples

      Planck.AI.stream(model, context, temperature: 1.0)
      |> Enum.each(fn
        {:text_delta, t} -> IO.write(t)
        _ -> :ok
      end)

  """
  @spec stream(Model.t(), Context.t()) :: Enumerable.t(Stream.t())
  @spec stream(Model.t(), Context.t(), keyword()) :: Enumerable.t(Stream.t())
  def stream(%Model{} = model, %Context{} = context, opts \\ []) do
    merged = Keyword.merge(model.default_opts, opts)
    {model_spec, messages, req_opts} = Adapter.to_req_llm(model, context, merged)

    case req_llm_client().stream_text(model_spec, messages, req_opts) do
      {:ok, response} ->
        response.stream |> Planck.AI.Stream.from_req_llm()

      {:error, reason} ->
        [{:error, reason}]
    end
  end

  @doc """
  Sends a request to the LLM and blocks until the full response is received.

  Internally consumes `stream/3` and assembles a `Message` from the events.
  Returns `{:ok, message}` on success or `{:error, reason}` on failure.

  ## Examples

      {:ok, %Planck.AI.Message{} = message} = Planck.AI.complete(model, context)

  """
  @spec complete(Model.t(), Context.t()) :: {:ok, Message.t()} | {:error, term()}
  @spec complete(Model.t(), Context.t(), keyword()) ::
          {:ok, Message.t()} | {:error, term()}
  def complete(%Model{} = model, %Context{} = context, opts \\ []) do
    model |> stream(context, opts) |> collect_stream()
  end

  @doc """
  Returns all supported provider atoms.

  ## Examples

      iex> Planck.AI.list_providers()
      [:anthropic, :openai, :google, :ollama, :llama_cpp]

  """
  @spec list_providers() :: [atom()]
  def list_providers, do: @providers

  @doc """
  Returns all known models for a given provider.

  Cloud providers (`:anthropic`, `:openai`, `:google`) source their catalog from
  LLMDB — a bundled snapshot loaded into `:persistent_term` on first call.

  Local providers (`:ollama`, `:llama_cpp`) query the running server at call time.
  Pass `base_url:` in `opts` to target a non-default server address.

  ## Examples

      iex> Planck.AI.list_models(:anthropic)
      [%Planck.AI.Model{provider: :anthropic, ...}, ...]

  """
  @spec list_models(atom()) :: [Model.t()]
  @spec list_models(atom(), keyword()) :: [Model.t()]
  def list_models(provider, opts \\ [])
  def list_models(:anthropic, opts), do: Anthropic.all(opts)
  def list_models(:openai, opts), do: OpenAI.all(opts)
  def list_models(:google, opts), do: Google.all(opts)
  def list_models(:ollama, opts), do: Ollama.all(opts)
  def list_models(:llama_cpp, opts), do: LlamaCpp.all(opts)
  def list_models(_, _), do: []

  @doc """
  Looks up a model by provider and id.

  Returns `{:ok, model}` if found, `{:error, :not_found}` otherwise.

  ## Examples

      iex> Planck.AI.get_model(:anthropic, "claude-sonnet-4-6")
      {:ok, %Planck.AI.Model{id: "claude-sonnet-4-6", ...}}

      iex> Planck.AI.get_model(:anthropic, "does-not-exist")
      {:error, :not_found}

      iex> Planck.AI.get_model(:llama_cpp, "mistral-7b", base_url: "http://10.0.0.5:8080")
      {:ok, %Planck.AI.Model{id: "mistral-7b", ...}}

  """
  @spec get_model(atom(), String.t()) :: {:ok, Model.t()} | {:error, :not_found}
  @spec get_model(atom(), String.t(), keyword()) :: {:ok, Model.t()} | {:error, :not_found}
  def get_model(provider, id, opts \\ []) do
    case Enum.find(list_models(provider, opts), &(&1.id == id)) do
      nil -> {:error, :not_found}
      model -> {:ok, model}
    end
  end

  # --- Private ---

  defp req_llm_client do
    Application.get_env(:planck_ai, :req_llm_client, Planck.AI.ReqLLM)
  end

  @spec collect_stream(Enumerable.t()) :: {:ok, Message.t()} | {:error, term()}
  defp collect_stream(stream) do
    result =
      Enum.reduce_while(stream, {:ok, []}, fn
        {:error, reason}, _ ->
          {:halt, {:error, reason}}

        {:done, _}, {:ok, parts} ->
          {:halt, {:ok, %Message{role: :assistant, content: Enum.reverse(parts)}}}

        {:text_delta, text}, {:ok, parts} ->
          {:cont, {:ok, [{:text, text} | parts]}}

        {:thinking_delta, text}, {:ok, parts} ->
          {:cont, {:ok, [{:thinking, text} | parts]}}

        {:tool_call_complete, %{id: id, name: name, args: args}}, {:ok, parts} ->
          {:cont, {:ok, [{:tool_call, id, name, args} | parts]}}

        _other, acc ->
          {:cont, acc}
      end)

    case result do
      {:ok, parts} when is_list(parts) ->
        {:ok, %Message{role: :assistant, content: Enum.reverse(parts)}}

      other ->
        other
    end
  end
end
