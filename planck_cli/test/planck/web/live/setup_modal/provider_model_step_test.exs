defmodule Planck.Web.Live.SetupModal.ProviderModelStepTest do
  use Planck.Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Planck.Headless.Config
  alias Planck.Web.Live.SetupModal.ProviderModelStep, as: Step

  # Manually-built socket, same technique SidecarWidgetTest uses to exercise
  # a LiveComponent's callbacks directly — avoids live_isolated/routing, and
  # (critically here) avoids ever reaching do_save/1's real config.json/.env
  # writes, since this component has no path-override seam for tests the
  # way Headless.configure_provider/1 itself does.
  defp build_socket(overrides) do
    {:ok, socket} =
      Step.update(
        %{mode: :add_provider, configured_providers: [], parent_id: "parent-id"},
        %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, myself: nil}}
      )

    update_in(socket.assigns, &Map.merge(&1, overrides))
  end

  # Same flattening technique SidecarWidgetTest's render_widget/1 uses —
  # calls the component's render/1 directly on an already-advanced socket's
  # assigns, bypassing the LiveComponent lifecycle (which render_component/2
  # would re-run from scratch, losing the state handle_event/3 built up).
  defp render_html(socket) do
    socket.assigns
    |> Step.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  describe "provider picker rendering" do
    test "includes typesafe and typesafe_compat as options via all_providers/0" do
      html =
        render_component(Step,
          id: "step",
          mode: :add_provider,
          configured_providers: [],
          parent_id: "parent-id"
        )

      assert html =~ "Typesafe"
      assert html =~ "Typesafe-compatible"
    end
  end

  describe "provider_type_for/1 persistence mapping" do
    test "cloud :typesafe persists as the \"typesafe\" config type" do
      assert Step.provider_type_for(:typesafe) == "typesafe"
    end

    test "local :typesafe_compat also persists as the \"typesafe\" config type" do
      assert Step.provider_type_for(:typesafe_compat) == "typesafe"
    end

    test "distinguished only by base_url, same as :openai/:openai_compat" do
      assert Step.provider_type_for(:openai) == Step.provider_type_for(:openai_compat)
      assert Step.provider_type_for(:typesafe) == Step.provider_type_for(:typesafe_compat)
    end
  end

  # typesafe_compat has no preset list — decider is too young a project to
  # bake in as a named preset (unlike ollama/llama_cpp for openai_compat) —
  # so, unlike openai_compat, it never requires a preset before advancing.
  describe "typesafe_compat has no preset step" do
    test "selecting typesafe_compat does not require picking a preset before advancing" do
      socket =
        build_socket(%{provider: :typesafe_compat, preset: nil, identifier: "", base_url: ""})

      {:noreply, socket} = Step.handle_event("next", %{}, socket)

      refute socket.assigns.error
    end

    test "advancing with an empty base_url does not attempt a network fetch" do
      socket =
        build_socket(%{
          provider: :typesafe_compat,
          preset: nil,
          identifier: "",
          base_url: ""
        })

      {:noreply, socket} = Step.handle_event("next", %{}, socket)

      assert_receive {:phoenix, :send_update,
                      {{Planck.Web.Live.SetupModal, "parent-id"},
                       %{action: :sub_step, value: :model}}}

      assert socket.assigns.sub_step == :model
      assert socket.assigns.provider_key == "typesafe-compat"
      assert socket.assigns.models == []
    end

    test "openai_compat still requires a preset before advancing" do
      socket = build_socket(%{provider: :openai_compat, preset: nil})

      {:noreply, socket} = Step.handle_event("next", %{}, socket)

      assert socket.assigns.error =~ "preset"
    end
  end

  # Regression: fetch_local_models/2's timeout branch used to be
  # `Task.shutdown(task, :brutal_kill) && []`. Task.shutdown/2 with
  # :brutal_kill always returns nil (it kills unconditionally, without
  # waiting to see whether a reply arrives), so `nil && []` always evaluated
  # to nil, not []. advance_to_model_step/1 then crashed in
  # `List.first(nil, {nil, nil})` — reproduced live against a decider
  # instance still loading its model weights, slow enough to miss the 2s
  # yield window. A fake HTTPClient here simulates that slowness without
  # a real slow server.
  describe "fetch_local_models/2 timeout handling" do
    defmodule SlowHTTPClient do
      @behaviour Planck.AI.HTTPClient

      @impl true
      def get(_url, _opts) do
        Process.sleep(2_100)
        {:ok, %{status: 200, body: %{"models" => []}}}
      end
    end

    setup do
      original = Application.get_env(:planck_ai, :http_client)
      Application.put_env(:planck_ai, :http_client, SlowHTTPClient)

      on_exit(fn ->
        if original,
          do: Application.put_env(:planck_ai, :http_client, original),
          else: Application.delete_env(:planck_ai, :http_client)
      end)

      :ok
    end

    test "advancing does not crash when the local endpoint is slower than the fetch timeout" do
      socket =
        build_socket(%{
          provider: :typesafe_compat,
          preset: nil,
          identifier: "",
          base_url: "http://localhost:8000"
        })

      {:noreply, socket} = Step.handle_event("next", %{}, socket)

      assert_receive {:phoenix, :send_update,
                      {{Planck.Web.Live.SetupModal, "parent-id"},
                       %{action: :sub_step, value: :model}}},
                     2_500

      assert socket.assigns.sub_step == :model
      assert socket.assigns.models == []
      assert socket.assigns.model_api_id == ""
    end
  end

  # Headless.configure_model/1 already refuses to persist default_model for
  # an rlcd provider unconditionally — this describe block is about the UI
  # not showing a checkbox that would silently do nothing, which is what
  # actually happened live: decider got added, "Set as default model" was
  # checked (its default state), and it silently became default_model,
  # breaking every session started afterward until it was manually fixed in
  # config.json.
  describe "the default-model checkbox is hidden for rlcd adds" do
    test "add_provider mode: hidden for :typesafe_compat, shown for :openai_compat" do
      rlcd_socket =
        build_socket(%{provider: :typesafe_compat, preset: nil, identifier: "", base_url: ""})

      {:noreply, rlcd_socket} = Step.handle_event("next", %{}, rlcd_socket)
      rlcd_html = render_html(rlcd_socket)

      refute rlcd_html =~ "Set as default model"
      assert rlcd_html =~ "can&#39;t be set as default"

      llm_socket =
        build_socket(%{
          provider: :openai_compat,
          preset: "ollama",
          base_url: "http://localhost:11434/v1",
          identifier: "",
          has_api_key: false
        })

      {:noreply, llm_socket} = Step.handle_event("next", %{}, llm_socket)
      llm_html = render_html(llm_socket)

      assert llm_html =~ "Set as default model"
      refute llm_html =~ "can&#39;t be set as default"
    end

    defmodule EmptyHTTPClient do
      @behaviour Planck.AI.HTTPClient

      @impl true
      def get(_url, _opts), do: {:ok, %{status: 200, body: %{"models" => []}}}
    end

    test "add_model mode: hidden when the selected configured provider is rlcd", %{} do
      original_providers = Application.get_env(:planck, :providers)
      original_client = Application.get_env(:planck_ai, :http_client)

      Application.put_env(:planck, :providers, %{
        "decider" => %{"type" => "typesafe", "base_url" => "http://localhost:8000"},
        "marvin" => %{"type" => "openai", "base_url" => "https://example.local/v1"}
      })

      # do_select_configured_provider/2 (via preselect_configured_provider/1,
      # since :add_model mode auto-selects configured_providers' first entry)
      # calls Planck.AI.list_models for real — stub the HTTP client so this
      # test doesn't depend on a real decider/marvin server being reachable.
      Application.put_env(:planck_ai, :http_client, EmptyHTTPClient)
      Config.reload_providers()

      on_exit(fn ->
        if original_providers,
          do: Application.put_env(:planck, :providers, original_providers),
          else: Application.delete_env(:planck, :providers)

        if original_client,
          do: Application.put_env(:planck_ai, :http_client, original_client),
          else: Application.delete_env(:planck_ai, :http_client)

        Config.reload_providers()
      end)

      rlcd_html =
        render_component(Step,
          id: "step",
          mode: :add_model,
          configured_providers: ["decider"],
          parent_id: "parent-id"
        )

      refute rlcd_html =~ "Set as default model"
      assert rlcd_html =~ "can&#39;t be set as default"

      llm_html =
        render_component(Step,
          id: "step",
          mode: :add_model,
          configured_providers: ["marvin"],
          parent_id: "parent-id"
        )

      assert llm_html =~ "Set as default model"
      refute llm_html =~ "can&#39;t be set as default"
    end
  end
end
