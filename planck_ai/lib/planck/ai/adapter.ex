defmodule Planck.AI.Adapter do
  @moduledoc """
  Translates between Planck's types and `req_llm`'s call interface.

  This is the only module that knows `req_llm`'s input and output shapes.
  Everything above this layer works exclusively with `Planck.AI` structs.
  """

  alias Planck.AI.{Context, Message, Model, Tool}
  alias ReqLLM.Message.ContentPart

  @doc """
  Converts a `Planck.AI.Model`, `Planck.AI.Context`, and call-site opts into
  the three arguments expected by `req_llm`'s `stream_text/3`:
  `{model_spec_string, req_llm_context, opts}`.

  Tools from the context are added to opts as `%ReqLLM.Tool{}` structs.
  Inference params (e.g. `temperature:`, `max_tokens:`) in opts are forwarded
  directly to `req_llm`, which handles per-provider translation.

  ## Examples

      iex> model = %Planck.AI.Model{id: "claude-sonnet-4-6", provider: :anthropic, context_window: 200_000, max_tokens: 8_096}
      iex> context = %Planck.AI.Context{messages: []}
      iex> {model_spec, _ctx, _opts} = Planck.AI.Adapter.to_req_llm(model, context, [])
      iex> model_spec
      "anthropic:claude-sonnet-4-6"

  """
  @spec to_req_llm(Model.t(), Context.t(), keyword()) ::
          {model_spec :: String.t() | map(), req_llm_context :: ReqLLM.Context.t(),
           opts :: keyword()}
  def to_req_llm(%Model{} = model, %Context{} = context, opts) do
    model_spec = build_model_spec(model)
    req_context = build_context(context)
    req_opts = opts |> add_base_url(model) |> add_tools(context.tools)
    {model_spec, req_context, req_opts}
  end

  # --- Private ---

  @spec build_model_spec(Model.t()) :: String.t() | map()
  defp build_model_spec(%Model{provider: :anthropic, id: id}), do: "anthropic:#{id}"
  defp build_model_spec(%Model{provider: :openai, id: id}), do: "openai:#{id}"
  defp build_model_spec(%Model{provider: :google, id: id}), do: "google:#{id}"
  defp build_model_spec(%Model{provider: :ollama, id: id}), do: %{provider: :ollama, id: id}
  defp build_model_spec(%Model{provider: :llama_cpp, id: id}), do: %{provider: :openai, id: id}

  @spec build_context(Context.t()) :: ReqLLM.Context.t()
  defp build_context(%Context{system: system, messages: messages}) do
    parts = Enum.flat_map(messages, &message_to_req_llm/1)
    parts = if system, do: [ReqLLM.Context.system(system) | parts], else: parts
    ReqLLM.Context.new(parts)
  end

  @spec add_base_url(keyword(), Model.t()) :: keyword()
  defp add_base_url(opts, %Model{base_url: nil}), do: opts

  defp add_base_url(opts, %Model{provider: p, base_url: url, api_key: key})
       when p in [:ollama, :llama_cpp] do
    opts
    |> Keyword.put_new(:base_url, url)
    |> Keyword.put_new(:api_key, key || "not-needed")
  end

  defp add_base_url(opts, %Model{base_url: url}), do: Keyword.put_new(opts, :base_url, url)

  @spec add_tools(keyword(), [Tool.t()]) :: keyword()
  defp add_tools(opts, []), do: opts

  defp add_tools(opts, tools) do
    req_tools =
      tools
      |> Enum.flat_map(fn tool ->
        case build_req_llm_tool(tool) do
          {:ok, t} -> [t]
          _error -> []
        end
      end)

    if req_tools == [], do: opts, else: Keyword.put(opts, :tools, req_tools)
  end

  @spec build_req_llm_tool(Tool.t()) :: {:ok, ReqLLM.Tool.t()} | {:error, term()}
  defp build_req_llm_tool(%Tool{name: name, description: desc, parameters: params}) do
    ReqLLM.Tool.new(
      name: name,
      description: desc,
      parameter_schema: params || %{},
      callback: fn _args -> {:ok, nil} end
    )
  end

  @spec message_to_req_llm(Message.t()) :: [term()]
  defp message_to_req_llm(%Message{role: :user, content: parts}) do
    [ReqLLM.Context.user(Enum.map(parts, &content_part_to_req_llm/1))]
  end

  defp message_to_req_llm(%Message{role: :assistant, content: parts}) do
    tool_calls =
      for {:tool_call, id, name, args} <- parts do
        ReqLLM.ToolCall.new(id, name, Jason.encode!(args))
      end

    case tool_calls do
      [] ->
        [ReqLLM.Context.assistant(Enum.map(parts, &content_part_to_req_llm/1))]

      _ ->
        text =
          Enum.find_value(parts, fn
            {:text, t} -> t
            _ -> nil
          end)

        [ReqLLM.Context.assistant(text || "", tool_calls: tool_calls)]
    end
  end

  defp message_to_req_llm(%Message{role: :tool_result, content: parts}) do
    for {:tool_result, id, result} <- parts do
      content = if is_binary(result), do: result, else: Jason.encode!(result)
      ReqLLM.Context.tool_result(id, content)
    end
  end

  @spec content_part_to_req_llm(Message.content_part()) :: term()
  defp content_part_to_req_llm({:text, text}), do: ContentPart.text(text)
  defp content_part_to_req_llm({:image, data, mime_type}), do: ContentPart.image(data, mime_type)
  defp content_part_to_req_llm({:image_url, url}), do: ContentPart.image_url(url)

  defp content_part_to_req_llm({:file, data, mime_type}),
    do: ContentPart.file(data, "", mime_type)

  defp content_part_to_req_llm({:video_url, url}), do: ContentPart.video_url(url)
  defp content_part_to_req_llm({:thinking, text}), do: ContentPart.thinking(text)

  defp content_part_to_req_llm({:tool_call, _id, _name, _args}),
    do: ContentPart.text("")

  defp content_part_to_req_llm({:tool_result, _id, _result}),
    do: ContentPart.text("")
end
