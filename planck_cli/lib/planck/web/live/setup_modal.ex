defmodule Planck.Web.Live.SetupModal do
  @moduledoc """
  Multi-step modal for configuring a model provider.

  Step 1 — Provider & credentials (API key or base URL).
  Step 2 — Model details (ID, display name, context window, thinking, opts).
  Step 3 — Save location and set-as-default.

  On success sends `:setup_complete` to the parent LiveView.
  """

  use Planck.Web, :live_component

  alias Planck.Headless

  @cloud_providers [:anthropic, :openai, :google]
  @local_providers [:openai_compat]

  @default_base_urls %{
    openai_compat: "http://localhost:11434"
  }

  @default_context_windows %{
    openai_compat: 128_000
  }

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:step, 1)
     |> assign(:provider, nil)
     |> assign(:credential, "")
     |> assign(:model_id, "")
     |> assign(:model_name, "")
     |> assign(:context_window, "")
     |> assign(:supports_thinking, false)
     |> assign(:advanced_opts, "")
     |> assign(:identifier, "")
     |> assign(:api_key, "")
     |> assign(:models, [])
     |> assign(:scope, :local)
     |> assign(:set_default, true)
     |> assign(:saving, false)
     |> assign(:error, nil)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, :first_run, assigns[:first_run] || false)}
  end

  @impl true
  def handle_event(event, params, socket)

  def handle_event("select_provider", %{"value" => value}, socket) do
    provider = String.to_existing_atom(value)
    default_cred = Map.get(@default_base_urls, provider, "")

    {:noreply,
     socket
     |> assign(:provider, provider)
     |> assign(:credential, default_cred)
     |> assign(:identifier, "")
     |> assign(:api_key, "")}
  end

  def handle_event("update_credential", %{"credential" => value}, socket) do
    {:noreply, assign(socket, :credential, value)}
  end

  def handle_event("select_model", %{"value" => model_id}, socket) do
    model_name =
      Enum.find_value(socket.assigns.models, "", fn {id, label} ->
        if id == model_id, do: label
      end)

    {:noreply,
     socket
     |> assign(:model_id, model_id)
     |> assign(
       :model_name,
       if(socket.assigns.model_name == "", do: model_name, else: socket.assigns.model_name)
     )}
  end

  def handle_event("update_model_fields", params, socket) do
    socket =
      socket
      |> maybe_assign(:model_id, params, "model_id")
      |> maybe_assign(:model_name, params, "model_name")
      |> maybe_assign(:context_window, params, "context_window")
      |> maybe_assign(:advanced_opts, params, "advanced_opts")
      |> maybe_assign(:identifier, params, "identifier")
      |> maybe_assign(:api_key, params, "api_key")

    supports_thinking =
      case Map.get(params, "supports_thinking") do
        nil -> socket.assigns.supports_thinking
        v -> v in ["true", "on"]
      end

    {:noreply, assign(socket, :supports_thinking, supports_thinking)}
  end

  def handle_event("toggle_thinking", _params, socket) do
    {:noreply, update(socket, :supports_thinking, &(!&1))}
  end

  def handle_event("select_scope", %{"value" => value}, socket) do
    {:noreply, assign(socket, :scope, String.to_existing_atom(value))}
  end

  def handle_event("toggle_default", _params, socket) do
    {:noreply, update(socket, :set_default, &(!&1))}
  end

  def handle_event("next", _params, %{assigns: %{step: 1}} = socket) do
    if socket.assigns.provider do
      provider = socket.assigns.provider
      credential = socket.assigns.credential
      default_ctx = Map.get(@default_context_windows, provider, "")

      models =
        if provider in @local_providers and credential != "" do
          fetch_local_models(provider, credential)
        else
          load_models(provider)
        end

      {:noreply,
       socket
       |> assign(:step, 2)
       |> assign(:models, models)
       |> assign(:context_window, to_string(default_ctx))
       |> assign(:error, nil)}
    else
      {:noreply, assign(socket, :error, pgettext("setup error", "Please select a provider."))}
    end
  end

  def handle_event("next", _params, %{assigns: %{step: 2}} = socket) do
    if socket.assigns.model_id != "" do
      {:noreply, socket |> assign(:step, 3) |> assign(:error, nil)}
    else
      {:noreply,
       assign(socket, :error, pgettext("setup error", "Please select or enter a model."))}
    end
  end

  def handle_event("back", _params, socket) do
    {:noreply, socket |> assign(:step, socket.assigns.step - 1) |> assign(:error, nil)}
  end

  def handle_event("save", _params, socket) do
    a = socket.assigns

    with {:ok, advanced_opts} <- parse_advanced_opts(a.advanced_opts) do
      socket = assign(socket, :saving, true)
      provider_key = derive_provider_key(a.provider, a.identifier)

      with :ok <- Headless.configure_provider(build_provider_opts(a, provider_key)),
           :ok <- Headless.configure_model(build_model_opts(a, provider_key, advanced_opts)) do
        send(self(), :setup_complete)
        {:noreply, socket}
      else
        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:saving, false)
           |> assign(:error, inspect(reason))}
      end
    else
      {:error, msg} ->
        {:noreply, assign(socket, :error, msg)}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec load_models(atom()) :: [{String.t(), String.t()}]
  defp load_models(provider) when provider in @cloud_providers do
    provider
    |> Planck.AI.list_models()
    |> Enum.map(&{&1.id, &1.id})
  end

  defp load_models(_local), do: []

  # Fetches available models from a running local server (2 s timeout).
  # Returns [] on error or timeout so the template falls back to a text input.
  @spec fetch_local_models(atom(), String.t()) :: [{String.t(), String.t()}]
  defp fetch_local_models(_provider, base_url) do
    task =
      Task.async(fn ->
        Planck.AI.list_models(:openai, base_url: base_url)
        |> Enum.map(&{&1.id, &1.id})
      end)

    case Task.yield(task, 2_000) do
      {:ok, models} -> models
      _ -> Task.shutdown(task, :brutal_kill) && []
    end
  rescue
    _ -> []
  end

  @spec maybe_assign(Phoenix.LiveView.Socket.t(), atom(), map(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  defp maybe_assign(socket, key, params, field) do
    case Map.fetch(params, field) do
      {:ok, value} -> assign(socket, key, value)
      :error -> socket
    end
  end

  @spec derive_provider_key(atom(), String.t()) :: String.t()
  defp derive_provider_key(:anthropic, _), do: "anthropic"
  defp derive_provider_key(:openai, _), do: "openai"
  defp derive_provider_key(:google, _), do: "google"
  defp derive_provider_key(:openai_compat, id) when is_binary(id) and id != "",
    do: String.downcase(id)

  defp derive_provider_key(:openai_compat, _), do: "openai-compat"

  @spec build_provider_opts(map(), String.t()) :: keyword()
  defp build_provider_opts(a, provider_key) do
    base = [id: provider_key, type: provider_type_for(a.provider), scope: a.scope]

    case a.provider do
      p when p in @cloud_providers ->
        if a.credential != "", do: [{:api_key, a.credential} | base], else: base

      :openai_compat ->
        base
        |> then(fn o -> if a.credential != "", do: [{:base_url, a.credential} | o], else: o end)
        |> then(fn o -> if a.identifier != "", do: [{:identifier, a.identifier} | o], else: o end)
        |> then(fn o -> if a.api_key != "", do: [{:api_key, a.api_key} | o], else: o end)
        |> then(fn o ->
          no_key = a.credential != "" and a.api_key == "" and a.identifier == ""
          if no_key, do: [{:has_api_key, false} | o], else: o
        end)
    end
  end

  @spec build_model_opts(map(), String.t(), map() | nil) :: keyword()
  defp build_model_opts(a, provider_key, params) do
    [
      id: a.model_id,
      model: a.model_id,
      provider: provider_key,
      scope: a.scope,
      default: a.set_default,
      params: params
    ]
  end

  @spec provider_type_for(atom()) :: String.t()
  defp provider_type_for(:anthropic), do: "anthropic"
  defp provider_type_for(:openai), do: "openai"
  defp provider_type_for(:google), do: "google"
  defp provider_type_for(:openai_compat), do: "openai"

  @spec parse_advanced_opts(String.t()) :: {:ok, map() | nil} | {:error, String.t()}
  defp parse_advanced_opts(""), do: {:ok, nil}

  defp parse_advanced_opts(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      {:ok, _} ->
        {:error, pgettext("setup error", "Advanced options must be a JSON object.")}

      {:error, _} ->
        {:error, pgettext("setup error", "Advanced options contain invalid JSON.")}
    end
  end

  @spec parse_context_window(String.t()) :: {:ok, pos_integer() | nil} | {:error, String.t()}
  defp parse_context_window(""), do: {:ok, nil}

  defp parse_context_window(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, pgettext("setup error", "Context window must be a positive integer.")}
    end
  end

  # ---------------------------------------------------------------------------
  # Template helpers
  # ---------------------------------------------------------------------------

  @doc false
  def cloud_provider?(provider), do: provider in @cloud_providers

  @doc false
  def local_provider?(provider), do: provider in @local_providers

  @doc false
  def custom_openai?(provider), do: provider == :custom_openai

  @doc false
  def credential_label(:anthropic), do: pgettext("setup label", "Anthropic API Key")
  def credential_label(:openai), do: pgettext("setup label", "OpenAI API Key")
  def credential_label(:google), do: pgettext("setup label", "Google API Key")
  def credential_label(:ollama), do: pgettext("setup label", "Ollama Base URL")
  def credential_label(:llama_cpp), do: pgettext("setup label", "llama.cpp Base URL")
  def credential_label(:custom_openai), do: pgettext("setup label", "Base URL")
  def credential_label(_), do: pgettext("setup label", "Credential")

  @doc false
  def credential_placeholder(:custom_openai), do: "https://integrate.api.nvidia.com/v1"
  def credential_placeholder(p) when p in @cloud_providers, do: "sk-..."
  def credential_placeholder(_), do: "http://localhost:11434"

  @doc false
  def provider_label(:anthropic), do: "Anthropic"
  def provider_label(:openai), do: "OpenAI"
  def provider_label(:google), do: "Google"
  def provider_label(:ollama), do: "Ollama"
  def provider_label(:llama_cpp), do: "llama.cpp"
  def provider_label(:custom_openai), do: "Custom (OpenAI-compatible)"
  def provider_label(p) when is_atom(p), do: Atom.to_string(p)
  def provider_label(_), do: ""

  @doc false
  def scope_label(:local), do: pgettext("setup label", "This project (.planck/)")
  def scope_label(:global), do: pgettext("setup label", "All projects (~/.planck/)")

  @doc false
  def all_providers do
    [:anthropic, :openai, :google, :ollama, :llama_cpp, :custom_openai]
    |> Enum.map(&{to_string(&1), provider_label(&1)})
  end

  @doc false
  def scope_options do
    [
      {"local", scope_label(:local)},
      {"global", scope_label(:global)}
    ]
  end
end
