defmodule Planck.Web.Live.SetupModal do
  @moduledoc """
  Multi-step modal for first-time provider/model setup and returning-user configuration.

  First run (no providers or models configured):
    Step :provider — Add a provider (type, credentials, preset for OpenAI-compatible)
    Step :model    — Add a model (picker, alias, default, params, scope)

  Returning users (⚙ button):
    Step :choose — pick action (configure provider or configure model)
    Then :provider or :model alone.

  On success sends `:setup_complete` to the parent LiveView.
  """

  use Planck.Web, :live_component

  alias Planck.Headless
  alias Phoenix.LiveView.Socket

  @type step :: :choose | :provider | :model
  @type mode :: :first_run | :choose | :add_provider | :add_model

  @cloud_providers [:anthropic, :openai, :google]
  @local_providers [:openai_compat]

  # {id, label, base_url, identifier, has_api_key}
  @openai_compat_presets [
    {"nvidia", "NVIDIA NIM", "https://integrate.api.nvidia.com/v1", "NVIDIA", true},
    {"groq", "Groq", "https://api.groq.com/openai/v1", "GROQ", true},
    {"ollama", "Ollama", "http://localhost:11434", nil, false},
    {"llama_cpp", "llama.cpp", "http://localhost:8080", nil, false},
    {"other", "Other", "", nil, true}
  ]

  @preset_default_params %{
    "nvidia" => %{"temperature" => 0.7, "top_p" => 0.8, "receive_timeout" => 600_000},
    "groq" => %{"temperature" => 0.5, "top_p" => 0.9}
  }

  @preset_default_models %{
    "nvidia" => "qwen/qwen3-coder-480b-a35b-instruct",
    "groq" => "llama-3.3-70b-versatile"
  }

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  @spec mount(Socket.t()) :: {:ok, Socket.t()}
  def mount(socket) do
    {:ok,
     socket
     |> assign(:step, :provider)
     |> assign(:mode, :first_run)
     |> assign(:first_run, false)
     |> assign(:provider, :openai_compat)
     |> assign(:preset, nil)
     |> assign(:api_key, "")
     |> assign(:base_url, "")
     |> assign(:identifier, "")
     |> assign(:has_api_key, true)
     |> assign(:provider_key, "")
     |> assign(:model_api_id, "")
     |> assign(:model_alias, "")
     |> assign(:models, [])
     |> assign(:configured_providers, [])
     |> assign(:scope, :local)
     |> assign(:set_default, true)
     |> assign(:advanced_opts, "")
     |> assign(:saving, false)
     |> assign(:error, nil)}
  end

  @impl true
  @spec update(map(), Socket.t()) :: {:ok, Socket.t()}
  def update(assigns, socket) do
    first_run = assigns[:first_run] || false

    configured_providers =
      case Headless.config() do
        %{providers: providers} when is_map(providers) and map_size(providers) > 0 ->
          providers |> Map.keys() |> Enum.sort()

        _ ->
          []
      end

    {:ok,
     socket
     |> assign(:first_run, first_run)
     |> assign(:step, if(first_run, do: :provider, else: :choose))
     |> assign(:mode, if(first_run, do: :first_run, else: :choose))
     |> assign(:configured_providers, configured_providers)}
  end

  # ---------------------------------------------------------------------------
  # Events — thin delegation layer
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event(event, params, socket)

  def handle_event("choose_action", %{"action" => action}, socket) do
    {:noreply, do_choose_action(socket, action)}
  end

  def handle_event("select_provider", %{"value" => value}, socket) do
    {:noreply, do_select_provider(socket, value)}
  end

  def handle_event("select_preset", %{"value" => preset_id}, socket) do
    {:noreply, do_select_preset(socket, preset_id)}
  end

  def handle_event("update_provider_fields", params, socket) do
    {:noreply, do_update_provider_fields(socket, params)}
  end

  def handle_event("select_configured_provider", %{"value" => provider_key}, socket) do
    {:noreply, do_select_configured_provider(socket, provider_key)}
  end

  def handle_event("select_model", %{"value" => model_api_id}, socket) do
    {:noreply, do_select_model(socket, model_api_id)}
  end

  def handle_event("update_model_fields", params, socket) do
    {:noreply, do_update_model_fields(socket, params)}
  end

  def handle_event("select_scope", %{"value" => value}, socket) do
    {:noreply, assign(socket, :scope, String.to_existing_atom(value))}
  end

  def handle_event("toggle_default", _params, socket) do
    {:noreply, update(socket, :set_default, &(!&1))}
  end

  def handle_event("next", _params, socket) do
    {:noreply, do_next(socket)}
  end

  def handle_event("back", _params, socket) do
    {:noreply, do_back(socket)}
  end

  def handle_event("save", _params, socket) do
    {:noreply, do_save(socket)}
  end

  # ---------------------------------------------------------------------------
  # Event handlers
  # ---------------------------------------------------------------------------

  @spec do_choose_action(Socket.t(), String.t()) :: Socket.t()
  defp do_choose_action(socket, "provider") do
    socket
    |> assign(:step, :provider)
    |> assign(:mode, :add_provider)
    |> assign(:error, nil)
  end

  defp do_choose_action(socket, "model") do
    socket
    |> preselect_configured_provider()
    |> assign(:step, :model)
    |> assign(:mode, :add_model)
    |> assign(:error, nil)
  end

  @spec do_select_provider(Socket.t(), String.t()) :: Socket.t()
  defp do_select_provider(socket, value) do
    socket
    |> assign(:provider, String.to_existing_atom(value))
    |> assign(:preset, nil)
    |> assign(:api_key, "")
    |> assign(:base_url, "")
    |> assign(:identifier, "")
    |> assign(:has_api_key, true)
  end

  @spec do_select_preset(Socket.t(), String.t()) :: Socket.t()
  defp do_select_preset(socket, preset_id) do
    {_id, _label, base_url, identifier, has_api_key} =
      Enum.find(@openai_compat_presets, {"other", "Other", "", nil, true}, fn {id, _, _, _, _} ->
        id == preset_id
      end)

    socket
    |> assign(:preset, preset_id)
    |> assign(:base_url, base_url)
    |> assign(:identifier, identifier || "")
    |> assign(:has_api_key, has_api_key)
    |> assign(:api_key, "")
  end

  @spec do_update_provider_fields(Socket.t(), map()) :: Socket.t()
  defp do_update_provider_fields(socket, params) do
    socket
    |> maybe_assign(:api_key, params, "api_key")
    |> maybe_assign(:base_url, params, "base_url")
    |> maybe_assign(:identifier, params, "identifier")
  end

  @spec do_select_configured_provider(Socket.t(), String.t()) :: Socket.t()
  defp do_select_configured_provider(socket, provider_key) do
    models = load_models_for_provider_key(provider_key)
    first_model = models |> List.first({nil, nil}) |> elem(0)

    socket
    |> assign(:provider_key, provider_key)
    |> assign(:models, models)
    |> assign(:model_api_id, first_model || "")
    |> assign(:model_alias, first_model || "")
  end

  @spec do_select_model(Socket.t(), String.t()) :: Socket.t()
  defp do_select_model(socket, model_api_id) do
    socket
    |> assign(:model_api_id, model_api_id)
    |> load_existing_model(model_api_id)
  end

  @spec do_update_model_fields(Socket.t(), map()) :: Socket.t()
  defp do_update_model_fields(socket, params) do
    socket
    |> maybe_assign(:model_api_id, params, "model_api_id")
    |> maybe_assign(:model_alias, params, "model_alias")
    |> maybe_assign(:advanced_opts, params, "advanced_opts")
  end

  @spec do_next(Socket.t()) :: Socket.t()
  defp do_next(%{assigns: %{step: :provider}} = socket) do
    case validate_provider_step(socket.assigns) do
      :ok -> advance_to_model_step(socket)
      {:error, msg} -> assign(socket, :error, msg)
    end
  end

  @spec do_back(Socket.t()) :: Socket.t()
  defp do_back(%{assigns: %{step: :model, mode: mode}} = socket)
       when mode in [:first_run, :add_provider] do
    socket
    |> assign(:step, :provider)
    |> assign(:error, nil)
  end

  defp do_back(socket) do
    socket
    |> assign(:step, :choose)
    |> assign(:mode, :choose)
    |> assign(:error, nil)
  end

  @spec do_save(Socket.t()) :: Socket.t()
  defp do_save(socket) do
    socket = assign(socket, :saving, true)
    a = socket.assigns

    provider_key =
      if a.provider_key == "" and a.mode != :add_model,
        do: compute_provider_key(a.provider, a.identifier, a.preset),
        else: a.provider_key

    socket = assign(socket, :provider_key, provider_key)

    with :ok <- validate_for_save(socket.assigns),
         {:ok, params} <- parse_advanced_opts(socket.assigns.advanced_opts),
         :ok <- maybe_save_provider(socket.assigns),
         :ok <- maybe_save_model(socket.assigns, params) do
      send(self(), :setup_complete)
      socket
    else
      {:error, reason} ->
        socket
        |> assign(:saving, false)
        |> assign(:error, format_error(reason))
    end
  end

  # ---------------------------------------------------------------------------
  # Assign helpers
  # ---------------------------------------------------------------------------

  @spec preselect_configured_provider(Socket.t()) :: Socket.t()
  defp preselect_configured_provider(socket) do
    case socket.assigns.configured_providers do
      [first | _] -> do_select_configured_provider(socket, first)
      [] -> socket
    end
  end

  @spec advance_to_model_step(Socket.t()) :: Socket.t()
  defp advance_to_model_step(socket) do
    a = socket.assigns
    provider_key = compute_provider_key(a.provider, a.identifier, a.preset)

    models =
      if a.provider in @local_providers and a.base_url != "",
        do: fetch_local_models(a.base_url),
        else: load_models(a.provider)

    preset_params = Map.get(@preset_default_params, a.preset || "")
    preset_model = Map.get(@preset_default_models, a.preset || "")
    advanced_opts = if preset_params, do: Jason.encode!(preset_params, pretty: true), else: ""
    first_model = preset_model || models |> List.first({nil, nil}) |> elem(0)

    socket
    |> assign(:provider_key, provider_key)
    |> assign(:step, :model)
    |> assign(:models, models)
    |> assign(:advanced_opts, advanced_opts)
    |> assign(:model_api_id, first_model || "")
    |> assign(:model_alias, first_model || "")
    |> assign(:error, nil)
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  @spec validate_provider_step(map()) :: :ok | {:error, String.t()}
  defp validate_provider_step(%{provider: nil}) do
    {:error, pgettext("setup error", "Please select a provider.")}
  end

  defp validate_provider_step(%{provider: :openai_compat, preset: nil}) do
    {:error, pgettext("setup error", "Please select a preset.")}
  end

  defp validate_provider_step(a) do
    provider_key = compute_provider_key(a.provider, a.identifier, a.preset)

    if Map.has_key?(Headless.config().providers || %{}, provider_key) do
      {:error,
       pgettext(
         "setup error",
         "A provider with this identifier already exists. Choose a different identifier."
       )}
    else
      :ok
    end
  end

  @spec validate_for_save(map()) :: :ok | {:error, String.t()}
  defp validate_for_save(%{mode: :add_model, provider_key: ""}) do
    {:error, pgettext("setup error", "Please select a provider.")}
  end

  defp validate_for_save(%{mode: :add_model, model_api_id: ""}) do
    {:error, pgettext("setup error", "Please select or enter a model.")}
  end

  defp validate_for_save(%{mode: :add_model}), do: :ok

  defp validate_for_save(a), do: validate_provider_step(a)

  # ---------------------------------------------------------------------------
  # Save helpers
  # ---------------------------------------------------------------------------

  @spec maybe_save_provider(map()) :: :ok | {:error, term()}
  defp maybe_save_provider(%{mode: :add_model}), do: :ok
  defp maybe_save_provider(a), do: Headless.configure_provider(build_provider_opts(a))

  @spec maybe_save_model(map(), map() | nil) :: :ok | {:error, String.t()}
  defp maybe_save_model(%{model_api_id: ""}, _params) do
    {:error, pgettext("setup error", "Please select or enter a model.")}
  end

  defp maybe_save_model(a, params) do
    Headless.configure_model(build_model_opts(a, a.provider_key, params))
  end

  # ---------------------------------------------------------------------------
  # Data helpers
  # ---------------------------------------------------------------------------

  @spec load_models(atom()) :: [{String.t(), String.t()}]
  defp load_models(provider) when provider in @cloud_providers do
    provider
    |> Planck.AI.list_models()
    |> Enum.map(&{&1.id, &1.id})
  end

  defp load_models(_local), do: []

  @spec fetch_local_models(String.t()) :: [{String.t(), String.t()}]
  defp fetch_local_models(base_url) do
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

  @spec load_models_for_provider_key(String.t()) :: [{String.t(), String.t()}]
  defp load_models_for_provider_key(provider_key) do
    case Headless.config().providers do
      %{^provider_key => %{"type" => type} = entry} ->
        provider = String.to_existing_atom(type)
        base_url = Map.get(entry, "base_url")
        if base_url, do: fetch_local_models(base_url), else: load_models(provider)

      _ ->
        []
    end
  end

  @spec maybe_assign(Socket.t(), atom(), map(), String.t()) :: Socket.t()
  defp maybe_assign(socket, key, params, field) do
    case Map.fetch(params, field) do
      {:ok, value} -> assign(socket, key, value)
      :error -> socket
    end
  end

  @spec load_existing_model(Socket.t(), String.t()) :: Socket.t()
  defp load_existing_model(socket, model_api_id) do
    provider_key = socket.assigns.provider_key
    config = Headless.config()

    existing =
      Enum.find(config.models, fn m ->
        Map.get(m, "model") == model_api_id and Map.get(m, "provider") == provider_key
      end)

    case existing do
      nil ->
        assign(socket, :model_alias, model_api_id)

      entry ->
        alias_val = Map.get(entry, "id", model_api_id)
        params = Map.get(entry, "params")
        advanced_opts = if params, do: Jason.encode!(params, pretty: true), else: ""
        is_default = config.default_model == alias_val

        socket
        |> assign(:model_alias, alias_val)
        |> assign(:advanced_opts, advanced_opts)
        |> assign(:set_default, is_default)
    end
  end

  @spec compute_provider_key(atom(), String.t(), String.t() | nil) :: String.t()
  defp compute_provider_key(:anthropic, _, _), do: "anthropic"
  defp compute_provider_key(:openai, _, _), do: "openai"
  defp compute_provider_key(:google, _, _), do: "google"

  defp compute_provider_key(:openai_compat, id, _)
       when is_binary(id) and id != "",
       do: String.downcase(id)

  defp compute_provider_key(:openai_compat, _, preset)
       when is_binary(preset) and preset not in ["", "other"],
       do: preset

  defp compute_provider_key(:openai_compat, _, _), do: "openai-compat"

  @spec build_provider_opts(map()) :: keyword()
  defp build_provider_opts(a) do
    base = [id: a.provider_key, type: provider_type_for(a.provider), scope: a.scope]

    case a.provider do
      p when p in @cloud_providers ->
        if a.api_key != "", do: [{:api_key, a.api_key} | base], else: base

      :openai_compat ->
        base
        |> prepend_if(:base_url, a.base_url, a.base_url != "")
        |> prepend_if(:identifier, a.identifier, a.identifier != "")
        |> prepend_if(:api_key, a.api_key, a.api_key != "")
        |> prepend_if(:has_api_key, false, not a.has_api_key)
    end
  end

  @spec prepend_if(keyword(), atom(), term(), boolean()) :: keyword()
  defp prepend_if(opts, _key, _val, false), do: opts
  defp prepend_if(opts, key, val, true), do: [{key, val} | opts]

  @spec build_model_opts(map(), String.t(), map() | nil) :: keyword()
  defp build_model_opts(a, provider_key, params) do
    alias_val = if a.model_alias != "", do: a.model_alias, else: a.model_api_id

    [
      id: alias_val,
      model: a.model_api_id,
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

  @spec format_error(term()) :: String.t()
  defp format_error(msg) when is_binary(msg), do: msg
  defp format_error(reason), do: inspect(reason)

  # ---------------------------------------------------------------------------
  # Template helpers
  # ---------------------------------------------------------------------------

  @doc false
  @spec cloud_provider?(atom()) :: boolean()
  def cloud_provider?(provider), do: provider in @cloud_providers

  @doc false
  @spec local_provider?(atom()) :: boolean()
  def local_provider?(provider), do: provider in @local_providers

  @doc false
  @spec credential_label(atom()) :: String.t()
  def credential_label(:anthropic), do: pgettext("setup label", "Anthropic API Key")
  def credential_label(:openai), do: pgettext("setup label", "OpenAI API Key")
  def credential_label(:google), do: pgettext("setup label", "Google API Key")
  def credential_label(_), do: pgettext("setup label", "API Key")

  @doc false
  @spec credential_placeholder(atom()) :: String.t()
  def credential_placeholder(p) when p in @cloud_providers, do: "sk-..."
  def credential_placeholder(_), do: "..."

  @doc false
  @spec provider_label(atom()) :: String.t()
  def provider_label(:anthropic), do: "Anthropic"
  def provider_label(:openai), do: "OpenAI"
  def provider_label(:google), do: "Google"
  def provider_label(:openai_compat), do: pgettext("setup label", "OpenAI-compatible")
  def provider_label(p) when is_atom(p), do: Atom.to_string(p)
  def provider_label(_), do: ""

  @doc false
  @spec scope_label(atom()) :: String.t()
  def scope_label(:local), do: pgettext("setup label", "This project (.planck/)")
  def scope_label(:global), do: pgettext("setup label", "All projects (~/.planck/)")

  @doc false
  @spec all_providers() :: [{String.t(), String.t()}]
  def all_providers do
    [:anthropic, :openai, :google, :openai_compat]
    |> Enum.map(&{to_string(&1), provider_label(&1)})
    |> Enum.sort_by(&elem(&1, 1))
  end

  @doc false
  @spec openai_compat_presets() :: [{String.t(), String.t()}]
  def openai_compat_presets do
    placeholder = {"", pgettext("setup label", "Select a preset…")}
    presets = Enum.map(@openai_compat_presets, fn {id, label, _, _, _} -> {id, label} end)
    [placeholder | presets]
  end

  @doc false
  @spec scope_options() :: [{String.t(), String.t()}]
  def scope_options do
    [
      {"local", scope_label(:local)},
      {"global", scope_label(:global)}
    ]
  end

  @doc false
  @spec step_subtitle(step(), mode()) :: String.t()
  def step_subtitle(step, mode) do
    case {step, mode} do
      {:choose, _} ->
        pgettext("setup subtitle", "What would you like to configure?")

      {:provider, m} when m in [:first_run, :add_provider] ->
        pgettext("setup subtitle", "Step 1 of 2 — Add a provider")

      {:provider, _} ->
        pgettext("setup subtitle", "Add a provider")

      {:model, m} when m in [:first_run, :add_provider] ->
        pgettext("setup subtitle", "Step 2 of 2 — Add a model")

      {:model, _} ->
        pgettext("setup subtitle", "Add a model")

      _ ->
        ""
    end
  end
end
