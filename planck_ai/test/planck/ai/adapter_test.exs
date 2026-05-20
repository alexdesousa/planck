defmodule Planck.AI.AdapterTest do
  use ExUnit.Case, async: true

  alias Planck.AI.{Adapter, Context, Message, Model, Tool}

  defp model(provider, opts \\ []) do
    %Model{
      id: Keyword.get(opts, :id, "test-model"),
      name: "Test",
      provider: provider,
      context_window: 4_096,
      max_tokens: 1_024,
      base_url: Keyword.get(opts, :base_url),
      api_key: Keyword.get(opts, :api_key),
      identifier: Keyword.get(opts, :identifier)
    }
  end

  defp empty_context(opts \\ []) do
    %Context{
      system: Keyword.get(opts, :system),
      messages: Keyword.get(opts, :messages, []),
      tools: Keyword.get(opts, :tools, [])
    }
  end

  defp to_req_llm(model, context \\ nil, opts \\ []) do
    Adapter.to_req_llm(model, context || empty_context(), opts)
  end

  # --- model spec ---

  describe "build_model_spec" do
    test "anthropic produces a provider:id string" do
      {spec, _, _} = to_req_llm(model(:anthropic, id: "claude-sonnet-4-6"))
      assert spec == "anthropic:claude-sonnet-4-6"
    end

    test "openai produces a provider:id string" do
      {spec, _, _} = to_req_llm(model(:openai, id: "gpt-4o"))
      assert spec == "openai:gpt-4o"
    end

    test "google produces a provider:id string" do
      {spec, _, _} = to_req_llm(model(:google, id: "gemini-2.5-flash"))
      assert spec == "google:gemini-2.5-flash"
    end

    test "openai with base_url produces an openai-provider map to bypass LLMDB lookup" do
      {spec, _, _} =
        to_req_llm(
          model(:openai,
            id: "meta/llama-3.3-70b-instruct",
            base_url: "https://integrate.api.nvidia.com/v1"
          )
        )

      assert spec == %{provider: :openai, id: "meta/llama-3.3-70b-instruct"}
    end

    test "uses model.model field as the API identifier when set" do
      {spec, _, _} =
        to_req_llm(%Model{
          id: "sonnet",
          model: "claude-sonnet-4-6",
          provider: :anthropic,
          context_window: 200_000,
          max_tokens: 8_096
        })

      assert spec == "anthropic:claude-sonnet-4-6"
    end

    test "falls back to model.id when model.model is nil" do
      {spec, _, _} = to_req_llm(model(:anthropic, id: "claude-sonnet-4-6"))
      assert spec == "anthropic:claude-sonnet-4-6"
    end
  end

  # --- base url / api key ---

  describe "add_base_url" do
    test "no-ops when base_url is nil" do
      {_, _, opts} = to_req_llm(model(:anthropic))
      refute Keyword.has_key?(opts, :base_url)
    end

    test "adds base_url for cloud provider with custom url" do
      {_, _, opts} = to_req_llm(model(:anthropic, base_url: "https://proxy.example.com"))
      assert opts[:base_url] == "https://proxy.example.com"
    end

    test "openai with base_url resolves api_key from env via identifier" do
      System.put_env("NVIDIA_API_KEY", "test-nvidia-key")
      on_exit(fn -> System.delete_env("NVIDIA_API_KEY") end)

      {_, _, opts} =
        to_req_llm(
          model(:openai,
            base_url: "https://integrate.api.nvidia.com/v1",
            identifier: "NVIDIA"
          )
        )

      assert opts[:api_key] == "test-nvidia-key"
    end

    test "openai with base_url defaults to OPENAI_API_KEY when no identifier" do
      System.put_env("OPENAI_API_KEY", "openai-compat-key")
      on_exit(fn -> System.delete_env("OPENAI_API_KEY") end)

      {_, _, opts} = to_req_llm(model(:openai, base_url: "http://localhost:11434"))
      assert opts[:api_key] == "openai-compat-key"
    end

    test "openai with base_url falls back to not-needed when no key is available" do
      System.delete_env("OPENAI_API_KEY")
      {_, _, opts} = to_req_llm(model(:openai, base_url: "http://localhost:11434"))
      assert opts[:api_key] == "not-needed"
    end

    test "openai with base_url and has_api_key: false always uses not-needed" do
      System.put_env("OPENAI_API_KEY", "should-not-be-used")
      on_exit(fn -> System.delete_env("OPENAI_API_KEY") end)

      {_, _, opts} =
        to_req_llm(%Model{
          id: "local",
          provider: :openai,
          base_url: "http://localhost:11434",
          has_api_key: false,
          context_window: 4_096,
          max_tokens: 2_048
        })

      assert opts[:api_key] == "not-needed"
    end
  end

  # --- tools ---

  describe "add_tools" do
    test "no-ops when tools list is empty" do
      {_, _, opts} = to_req_llm(model(:anthropic))
      refute Keyword.has_key?(opts, :tools)
    end

    test "adds valid tools to opts" do
      tool =
        Tool.new(
          name: "ls",
          description: "List files",
          parameters: %{"type" => "object", "properties" => %{}}
        )

      {_, _, opts} = to_req_llm(model(:anthropic), empty_context(tools: [tool]))
      assert [req_tool] = opts[:tools]
      assert req_tool.name == "ls"
    end

    test "silently drops tools that fail ReqLLM.Tool validation" do
      bad_tool = %Tool{name: nil, description: nil, parameters: nil}
      {_, _, opts} = to_req_llm(model(:anthropic), empty_context(tools: [bad_tool]))
      refute Keyword.has_key?(opts, :tools)
    end
  end

  # --- context / system ---

  describe "build_context" do
    test "includes system message when present" do
      {_, ctx, _} = to_req_llm(model(:anthropic), empty_context(system: "Be helpful."))
      assert Enum.any?(ctx.messages, &(&1.role == :system))
    end

    test "omits system message when nil" do
      {_, ctx, _} = to_req_llm(model(:anthropic), empty_context(system: nil))
      refute Enum.any?(ctx.messages, &(&1.role == :system))
    end
  end

  # --- message conversion ---

  describe "user messages" do
    test "converts text content" do
      context = empty_context(messages: [%Message{role: :user, content: [{:text, "Hello"}]}])
      {_, ctx, _} = to_req_llm(model(:anthropic), context)
      assert Enum.any?(ctx.messages, &(&1.role == :user))
    end

    test "converts image content" do
      context =
        empty_context(
          messages: [
            %Message{
              role: :user,
              content: [{:image, <<1, 2, 3>>, "image/png"}, {:text, "what is this?"}]
            }
          ]
        )

      assert {_, _, _} = to_req_llm(model(:anthropic), context)
    end

    test "converts image_url content" do
      context =
        empty_context(
          messages: [
            %Message{role: :user, content: [{:image_url, "https://example.com/photo.png"}]}
          ]
        )

      assert {_, _, _} = to_req_llm(model(:anthropic), context)
    end

    test "converts file content" do
      context =
        empty_context(
          messages: [
            %Message{role: :user, content: [{:file, <<1, 2, 3>>, "application/pdf"}]}
          ]
        )

      assert {_, _, _} = to_req_llm(model(:anthropic), context)
    end

    test "converts video_url content" do
      context =
        empty_context(
          messages: [
            %Message{role: :user, content: [{:video_url, "https://example.com/clip.mp4"}]}
          ]
        )

      assert {_, _, _} = to_req_llm(model(:anthropic), context)
    end
  end

  describe "assistant messages" do
    test "converts text-only assistant message" do
      context =
        empty_context(
          messages: [
            %Message{role: :assistant, content: [{:text, "Hello!"}]}
          ]
        )

      {_, ctx, _} = to_req_llm(model(:anthropic), context)
      assert Enum.any?(ctx.messages, &(&1.role == :assistant))
    end

    test "converts assistant message with tool calls" do
      context =
        empty_context(
          messages: [
            %Message{role: :assistant, content: [{:tool_call, "tc_1", "ls", %{"path" => "/tmp"}}]}
          ]
        )

      {_, ctx, _} = to_req_llm(model(:anthropic), context)
      assert Enum.any?(ctx.messages, &(&1.role == :assistant))
    end

    test "converts assistant message with tool calls and accompanying text" do
      context =
        empty_context(
          messages: [
            %Message{
              role: :assistant,
              content: [
                {:text, "Let me check that."},
                {:tool_call, "tc_1", "ls", %{"path" => "/tmp"}}
              ]
            }
          ]
        )

      {_, ctx, _} = to_req_llm(model(:anthropic), context)
      assert Enum.any?(ctx.messages, &(&1.role == :assistant))
    end
  end

  describe "tool_result messages" do
    test "converts tool result with string content" do
      context =
        empty_context(
          messages: [
            %Message{
              role: :tool_result,
              content: [{:tool_result, "tc_1", "file1.txt\nfile2.txt"}]
            }
          ]
        )

      {_, ctx, _} = to_req_llm(model(:anthropic), context)
      assert Enum.any?(ctx.messages, &(&1.role == :tool))
    end

    test "converts tool result with non-string content via JSON encoding" do
      context =
        empty_context(
          messages: [
            %Message{
              role: :tool_result,
              content: [{:tool_result, "tc_1", %{"files" => ["a", "b"]}}]
            }
          ]
        )

      assert {_, _, _} = to_req_llm(model(:anthropic), context)
    end
  end
end
