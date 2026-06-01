defmodule Planck.Web.Live.SetupModal.ProviderModelStep do
  @moduledoc """
  The combined provider+model step LiveComponent.

  Owns all provider and model state, plus the internal sub-step
  (`:provider` or `:model`). Reports sub-step changes and completion
  to the parent `SetupModal` via `send_update/2`.

  Receives:
  - `mode` — `:add_provider` or `:add_model`
  - `configured_providers` — list of configured provider keys
  - `parent_id` — the id of the parent SetupModal LiveComponent
  """

  use Planck.Web, :live_component

  alias Planck.Headless
  alias Phoenix.LiveView.Socket

  @cloud_providers [:anthropic, :openai, :google]
  @local_providers [:openai_compat]

  # {id, label, base_url, identifier, has_api_key}
  @openai_compat_presets [
    {"nvidia", "NVIDIA NIM", "https://integrate.api.nvidia.com/v1", "NVIDIA", true},
    {"groq", "Groq", "https://api.groq.com/openai/v1", "GROQ", true},
    {"ollama", "Ollama", "http://localhost:11434/v1", nil, false},
    {"llama_cpp", "llama.cpp", "http://localhost:8080/v1", nil, false},
    {"other", "Other", "", nil, true}
  ]

  # ---------------------------------------------------------------------------
  # Module-attribute accessors (used by SetupModal and template helpers)
  # ---------------------------------------------------------------------------

  @doc "Returns the list of OpenAI-compatible preset tuples."
  @spec openai_compat_presets_data() :: [
          {String.t(), String.t(), String.t(), String.t() | nil, boolean()}
        ]
  def openai_compat_presets_data, do: @openai_compat_presets

  @doc "Returns the list of cloud provider atoms."
  @spec cloud_providers() :: [atom()]
  def cloud_providers, do: @cloud_providers

  @doc "Returns the list of local provider atoms."
  @spec local_providers() :: [atom()]
  def local_providers, do: @local_providers

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  @spec update(map(), Socket.t()) :: {:ok, Socket.t()}
  def update(%{action: :go_back}, %{assigns: %{mode: :add_model}} = socket) do
    send_update(Planck.Web.Live.SetupModal,
      id: socket.assigns.parent_id,
      action: :cancel
    )

    {:ok, socket}
  end

  def update(%{action: :go_back}, socket) do
    {:ok, assign(socket, :sub_step, :provider)}
  end

  def update(%{action: :next}, socket) do
    {:noreply, socket} = handle_event("next", %{}, socket)
    {:ok, socket}
  end

  def update(%{action: :save}, socket) do
    {:noreply, socket} = handle_event("save", %{}, socket)
    {:ok, socket}
  end

  def update(%{action: _} = _msg, socket), do: {:ok, socket}

  def update(assigns, socket) do
    mode = assigns[:mode] || :add_provider
    configured_providers = assigns[:configured_providers] || []
    parent_id = assigns[:parent_id]

    socket =
      socket
      |> assign(:mode, mode)
      |> assign(:configured_providers, configured_providers)
      |> assign(:parent_id, parent_id)
      |> assign_new(:provider, fn -> :openai_compat end)
      |> assign_new(:preset, fn -> nil end)
      |> assign_new(:api_key, fn -> "" end)
      |> assign_new(:base_url, fn -> "" end)
      |> assign_new(:identifier, fn -> "" end)
      |> assign_new(:has_api_key, fn -> true end)
      |> assign_new(:provider_key, fn -> "" end)
      |> assign_new(:model_api_id, fn -> "" end)
      |> assign_new(:model_alias, fn -> "" end)
      |> assign_new(:models, fn -> [] end)
      |> assign_new(:scope, fn -> :local end)
      |> assign_new(:set_default, fn -> true end)
      |> assign_new(:advanced_opts, fn -> "" end)
      |> assign_new(:param_context_window, fn -> "" end)
      |> assign_new(:param_max_tokens, fn -> "" end)
      |> assign_new(:param_temperature, fn -> "" end)
      |> assign_new(:param_top_p, fn -> "" end)
      |> assign_new(:param_min_p, fn -> "" end)
      |> assign_new(:param_top_k, fn -> "" end)
      |> assign_new(:params_open, fn -> false end)
      |> assign_new(:saving, fn -> false end)
      |> assign_new(:error, fn -> nil end)

    socket =
      case mode do
        :add_model ->
          socket
          |> assign(:sub_step, :model)
          |> preselect_configured_provider()

        _ ->
          assign_new(socket, :sub_step, fn -> :provider end)
      end

    {:ok, socket}
  end

  # ---------------------------------------------------------------------------
  # Events — provider sub-step
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event(event, params, socket)

  def handle_event("select_provider", %{"value" => value}, socket) do
    socket =
      socket
      |> assign(:provider, String.to_existing_atom(value))
      |> assign(:preset, nil)
      |> assign(:api_key, "")
      |> assign(:base_url, "")
      |> assign(:identifier, "")
      |> assign(:has_api_key, true)

    {:noreply, socket}
  end

  def handle_event("select_preset", %{"value" => preset_id}, socket) do
    {_id, _label, base_url, identifier, has_api_key} =
      Enum.find(@openai_compat_presets, {"other", "Other", "", nil, true}, fn {id, _, _, _, _} ->
        id == preset_id
      end)

    socket =
      socket
      |> assign(:preset, preset_id)
      |> assign(:base_url, base_url)
      |> assign(:identifier, identifier || "")
      |> assign(:has_api_key, has_api_key)
      |> assign(:api_key, "")

    {:noreply, socket}
  end

  def handle_event("update_provider_fields", params, socket) do
    socket =
      socket
      |> maybe_assign(:api_key, params, "api_key")
      |> maybe_assign(:base_url, params, "base_url")
      |> maybe_assign(:identifier, params, "identifier")

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Events — model sub-step
  # ---------------------------------------------------------------------------

  def handle_event("select_configured_provider", %{"value" => provider_key}, socket) do
    {:noreply, do_select_configured_provider(socket, provider_key)}
  end

  def handle_event("select_model", %{"value" => model_api_id}, socket) do
    {:noreply, do_select_model(socket, model_api_id)}
  end

  def handle_event("update_model_fields", params, socket) do
    socket =
      socket
      |> maybe_assign(:model_api_id, params, "model_api_id")
      |> maybe_assign(:model_alias, params, "model_alias")
      |> maybe_assign(:advanced_opts, params, "advanced_opts")
      |> maybe_assign(:param_context_window, params, "param_context_window")
      |> maybe_assign(:param_max_tokens, params, "param_max_tokens")
      |> maybe_assign(:param_temperature, params, "param_temperature")
      |> maybe_assign(:param_top_p, params, "param_top_p")
      |> maybe_assign(:param_min_p, params, "param_min_p")
      |> maybe_assign(:param_top_k, params, "param_top_k")

    {:noreply, socket}
  end

  def handle_event("select_scope", %{"value" => value}, socket) do
    {:noreply, assign(socket, :scope, String.to_existing_atom(value))}
  end

  def handle_event("toggle_default", _params, socket) do
    {:noreply, update(socket, :set_default, &(!&1))}
  end

  def handle_event("toggle_params", _params, socket) do
    {:noreply, update(socket, :params_open, &(!&1))}
  end

  # ---------------------------------------------------------------------------
  # Navigation events (called from parent's button bar via phx-target)
  # ---------------------------------------------------------------------------

  def handle_event("next", _params, socket) do
    case validate_provider_step(socket.assigns) do
      :ok ->
        socket = advance_to_model_step(socket)

        send_update(Planck.Web.Live.SetupModal,
          id: socket.assigns.parent_id,
          action: :sub_step,
          value: :model
        )

        {:noreply, socket}

      {:error, msg} ->
        {:noreply, assign(socket, :error, msg)}
    end
  end

  def handle_event("back", _params, socket) do
    case socket.assigns do
      %{sub_step: :model, mode: mode} when mode in [:add_provider] ->
        socket =
          socket
          |> assign(:sub_step, :provider)
          |> assign(:error, nil)

        send_update(Planck.Web.Live.SetupModal,
          id: socket.assigns.parent_id,
          action: :sub_step,
          value: :provider
        )

        {:noreply, socket}

      _ ->
        send_update(Planck.Web.Live.SetupModal,
          id: socket.assigns.parent_id,
          action: :cancel
        )

        {:noreply, socket}
    end
  end

  def handle_event("save", _params, socket) do
    {:noreply, do_save(socket)}
  end

  # ---------------------------------------------------------------------------
  # Save
  # ---------------------------------------------------------------------------

  @spec do_save(Socket.t()) :: Socket.t()
  defp do_save(socket) do
    socket = assign(socket, :saving, true)

    send_update(Planck.Web.Live.SetupModal,
      id: socket.assigns.parent_id,
      action: :saving,
      value: true
    )

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
      send_update(Planck.Web.Live.SetupModal,
        id: socket.assigns.parent_id,
        action: :complete
      )

      socket
    else
      {:error, reason} ->
        send_update(Planck.Web.Live.SetupModal,
          id: socket.assigns.parent_id,
          action: :saving,
          value: false
        )

        socket
        |> assign(:saving, false)
        |> assign(:error, format_error(reason))
    end
  end

  # ---------------------------------------------------------------------------
  # Navigation helpers
  # ---------------------------------------------------------------------------

  @spec preselect_configured_provider(Socket.t()) :: Socket.t()
  defp preselect_configured_provider(socket) do
    case socket.assigns.configured_providers do
      [first | _] -> do_select_configured_provider(socket, first)
      [] -> socket
    end
  end

  @spec do_select_configured_provider(Socket.t(), String.t()) :: Socket.t()
  defp do_select_configured_provider(socket, provider_key) do
    models = load_models_for_provider_key(provider_key)
    first_model = models |> List.first({nil, nil}) |> elem(0)

    socket
    |> assign(:provider_key, provider_key)
    |> assign(:models, models)
    |> clear_param_assigns()
    |> then(fn s ->
      if first_model, do: do_select_model(s, first_model), else: assign(s, :model_api_id, "")
    end)
  end

  @spec do_select_model(Socket.t(), String.t()) :: Socket.t()
  defp do_select_model(socket, model_api_id) do
    socket
    |> assign(:model_api_id, model_api_id)
    |> load_existing_model(model_api_id)
  end

  @spec advance_to_model_step(Socket.t()) :: Socket.t()
  defp advance_to_model_step(socket) do
    a = socket.assigns
    provider_key = compute_provider_key(a.provider, a.identifier, a.preset)

    preset_default_params = %{
      "nvidia" => %{"temperature" => 0.7, "top_p" => 0.8, "receive_timeout" => 600_000},
      "groq" => %{"temperature" => 0.5, "top_p" => 0.9}
    }

    preset_default_models = %{
      "nvidia" => "qwen/qwen3-coder-480b-a35b-instruct",
      "groq" => "llama-3.3-70b-versatile"
    }

    models =
      if a.provider in @local_providers and a.base_url != "",
        do: fetch_local_models(a.base_url),
        else: load_models(a.provider)

    preset_params = Map.get(preset_default_params, a.preset || "")
    preset_model = Map.get(preset_default_models, a.preset || "")
    first_model = preset_model || models |> List.first({nil, nil}) |> elem(0)

    socket
    |> assign(:provider_key, provider_key)
    |> assign(:sub_step, :model)
    |> assign(:models, models)
    |> assign(:model_api_id, first_model || "")
    |> assign(:model_alias, first_model || "")
    |> assign(:error, nil)
    |> assign_preset_params(preset_params)
  end

  @spec assign_preset_params(Socket.t(), map() | nil) :: Socket.t()
  defp assign_preset_params(socket, preset_params) do
    {known_params, remaining_params} = extract_known_params(preset_params || %{})

    advanced_opts =
      if remaining_params != %{}, do: Jason.encode!(remaining_params, pretty: true), else: ""

    socket
    |> assign(:advanced_opts, advanced_opts)
    |> assign(:param_context_window, "")
    |> assign(:param_max_tokens, "")
    |> assign(:param_temperature, param_to_string(known_params["temperature"]))
    |> assign(:param_top_p, param_to_string(known_params["top_p"]))
    |> assign(:param_min_p, param_to_string(known_params["min_p"]))
    |> assign(:param_top_k, param_to_string(known_params["top_k"]))
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

    if Map.has_key?(Headless.config().providers, provider_key) do
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
  defp load_models(provider) when provider in [:anthropic, :openai, :google] do
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

  @spec clear_param_assigns(Socket.t()) :: Socket.t()
  defp clear_param_assigns(socket) do
    socket
    |> assign(:param_context_window, "")
    |> assign(:param_max_tokens, "")
    |> assign(:param_temperature, "")
    |> assign(:param_top_p, "")
    |> assign(:param_min_p, "")
    |> assign(:param_top_k, "")
  end

  @spec extract_known_params(map()) :: {map(), map()}
  defp extract_known_params(params) do
    known_keys = ["temperature", "top_p", "min_p", "top_k"]
    {Map.take(params, known_keys), Map.drop(params, known_keys)}
  end

  @spec param_to_string(number() | nil) :: String.t()
  defp param_to_string(nil), do: ""
  defp param_to_string(val), do: to_string(val)

  @spec int_to_string(integer() | nil) :: String.t()
  defp int_to_string(nil), do: ""
  defp int_to_string(val), do: to_string(val)

  @spec parse_float(String.t()) :: {:ok, float()} | :error
  defp parse_float(""), do: :error

  defp parse_float(s) do
    case Float.parse(String.trim(s)) do
      {f, _} -> {:ok, f}
      :error -> :error
    end
  end

  @spec parse_integer(String.t()) :: {:ok, integer()} | :error
  defp parse_integer(""), do: :error

  defp parse_integer(s) do
    case Integer.parse(String.trim(s)) do
      {i, ""} -> {:ok, i}
      _ -> :error
    end
  end

  @spec put_if_parsed(keyword(), atom(), String.t(), (String.t() -> {:ok, term()} | :error)) ::
          keyword()
  defp put_if_parsed(opts, key, val, parser) do
    case parser.(val) do
      {:ok, parsed} -> Keyword.put(opts, key, parsed)
      :error -> opts
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
        {known_params, remaining_params} = extract_known_params(Map.get(entry, "params") || %{})

        advanced_opts =
          if remaining_params != %{}, do: Jason.encode!(remaining_params, pretty: true), else: ""

        is_default = config.default_model == alias_val

        socket
        |> assign(:model_alias, alias_val)
        |> assign(:advanced_opts, advanced_opts)
        |> assign(:set_default, is_default)
        |> assign(:param_context_window, int_to_string(Map.get(entry, "context_window")))
        |> assign(:param_max_tokens, int_to_string(Map.get(entry, "max_tokens")))
        |> assign(:param_temperature, param_to_string(known_params["temperature"]))
        |> assign(:param_top_p, param_to_string(known_params["top_p"]))
        |> assign(:param_min_p, param_to_string(known_params["min_p"]))
        |> assign(:param_top_k, param_to_string(known_params["top_k"]))
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

    if a.provider in @cloud_providers do
      if a.api_key != "", do: [{:api_key, a.api_key} | base], else: base
    else
      base
      |> prepend_if(:base_url, a.base_url, a.base_url != "")
      |> prepend_if(:identifier, a.identifier, a.identifier != "")
      |> prepend_if(:api_key, a.api_key, a.api_key != "")
      |> prepend_if(:has_api_key, false, not a.has_api_key)
    end
  end

  @spec merge_param(map(), String.t(), String.t(), (String.t() -> {:ok, term()} | :error)) ::
          map()
  defp merge_param(acc, key, _val, _parser) when is_map_key(acc, key), do: acc

  defp merge_param(acc, key, val, parser) do
    case parser.(val) do
      {:ok, parsed} -> Map.put(acc, key, parsed)
      :error -> acc
    end
  end

  @spec prepend_if(keyword(), atom(), term(), boolean()) :: keyword()
  defp prepend_if(opts, _key, _val, false), do: opts
  defp prepend_if(opts, key, val, true), do: [{key, val} | opts]

  @spec build_model_opts(map(), String.t(), map() | nil) :: keyword()
  defp build_model_opts(a, provider_key, json_params) do
    alias_val = if a.model_alias != "", do: a.model_alias, else: a.model_api_id

    merged_params =
      [
        {"temperature", a.param_temperature, &parse_float/1},
        {"top_p", a.param_top_p, &parse_float/1},
        {"min_p", a.param_min_p, &parse_float/1},
        {"top_k", a.param_top_k, &parse_integer/1}
      ]
      |> Enum.reduce(json_params || %{}, fn {key, val, parser}, acc ->
        merge_param(acc, key, val, parser)
      end)
      |> then(fn p -> if p == %{}, do: nil, else: p end)

    [
      id: alias_val,
      model: a.model_api_id,
      provider: provider_key,
      scope: a.scope,
      default: a.set_default,
      params: merged_params
    ]
    |> put_if_parsed(:context_window, a.param_context_window, &parse_integer/1)
    |> put_if_parsed(:max_tokens, a.param_max_tokens, &parse_integer/1)
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

  @spec maybe_assign(Socket.t(), atom(), map(), String.t()) :: Socket.t()
  defp maybe_assign(socket, key, params, field) do
    case Map.fetch(params, field) do
      {:ok, value} -> assign(socket, key, value)
      :error -> socket
    end
  end

  # ---------------------------------------------------------------------------
  # Template helpers
  # ---------------------------------------------------------------------------

  defp cloud_provider?(provider), do: provider in @cloud_providers

  defp credential_label(:anthropic), do: pgettext("setup label", "Anthropic API Key")
  defp credential_label(:openai), do: pgettext("setup label", "OpenAI API Key")
  defp credential_label(:google), do: pgettext("setup label", "Google API Key")
  defp credential_label(_), do: pgettext("setup label", "API Key")

  defp credential_placeholder(p) when p in @cloud_providers, do: "sk-..."
  defp credential_placeholder(_), do: "..."

  defp provider_label(:anthropic), do: "Anthropic"
  defp provider_label(:openai), do: "OpenAI"
  defp provider_label(:google), do: "Google"
  defp provider_label(:openai_compat), do: pgettext("setup label", "OpenAI-compatible")
  defp provider_label(p) when is_atom(p), do: Atom.to_string(p)
  defp provider_label(_), do: ""

  defp all_providers do
    [:anthropic, :openai, :google, :openai_compat]
    |> Enum.map(&{to_string(&1), provider_label(&1)})
    |> Enum.sort_by(&elem(&1, 1))
  end

  defp openai_compat_presets do
    placeholder = {"", pgettext("setup label", "Select a preset…")}
    presets = Enum.map(@openai_compat_presets, fn {id, label, _, _, _} -> {id, label} end)
    [placeholder | presets]
  end

  defp scope_label(:local), do: pgettext("setup label", "This project (.planck/)")
  defp scope_label(:global), do: pgettext("setup label", "All projects (~/.planck/)")

  defp scope_options do
    [
      {"local", scope_label(:local)},
      {"global", scope_label(:global)}
    ]
  end

  # ---------------------------------------------------------------------------
  # Template
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <%= if @sub_step == :provider do %>
        <div class="space-y-3">

          <%!-- Provider type picker --%>
          <div>
            <label class="font-mono text-xs text-muted-foreground block mb-1">
              <%= pgettext("setup label", "Provider type") %>
            </label>
            <.dropdown
              id="setup-provider"
              name="provider"
              options={all_providers()}
              selected={if @provider, do: to_string(@provider), else: ""}
              on_select="select_provider"
              target={@myself}
            />
          </div>

          <%!-- Cloud providers: API key --%>
          <%= if @provider && cloud_provider?(@provider) do %>
            <div>
              <label class="font-mono text-xs text-muted-foreground block mb-1">
                <%= credential_label(@provider) %>
                <span class="opacity-50 ml-1"><%= pgettext("setup label", "(optional — set via env var instead)") %></span>
              </label>
              <form phx-change="update_provider_fields" phx-target={@myself}>
                <input
                  type="password"
                  name="api_key"
                  value={@api_key}
                  class="w-full border-2 border-black px-2 py-1.5 font-mono text-sm
                         bg-background focus:outline-none shadow-[2px_2px_0px_#000]
                         placeholder:text-muted-foreground"
                  placeholder={credential_placeholder(@provider)}
                />
              </form>
            </div>
          <% end %>

          <%!-- OpenAI-compatible: preset picker --%>
          <%= if @provider == :openai_compat do %>
            <div>
              <label class="font-mono text-xs text-muted-foreground block mb-1">
                <%= pgettext("setup label", "Preset") %>
              </label>
              <.dropdown
                id="setup-preset"
                name="preset"
                options={openai_compat_presets()}
                selected={@preset || ""}
                on_select="select_preset"
                target={@myself}
              />
            </div>

            <%= if @preset do %>
              <form phx-change="update_provider_fields" phx-target={@myself} class="space-y-3">

                <%!-- Base URL --%>
                <div>
                  <label class="font-mono text-xs text-muted-foreground block mb-1">
                    <%= pgettext("setup label", "Base URL") %>
                  </label>
                  <input
                    type="text"
                    name="base_url"
                    value={@base_url}
                    class="w-full border-2 border-black px-2 py-1.5 font-mono text-sm
                           bg-background focus:outline-none shadow-[2px_2px_0px_#000]
                           placeholder:text-muted-foreground"
                    placeholder="http://localhost:11434/v1"
                  />
                  <p class="font-mono text-xs text-muted-foreground mt-1">
                    <%= pgettext("setup help", "Must include /v1 — e.g. http://localhost:11434/v1") %>
                  </p>
                </div>

                <%!-- Identifier — always shown, used as provider key --%>
                <div>
                  <label class="font-mono text-xs text-muted-foreground block mb-1">
                    <%= pgettext("setup label", "Identifier") %>
                    <span class="opacity-50 ml-1"><%= pgettext("setup label", "(optional)") %></span>
                  </label>
                  <input
                    type="text"
                    name="identifier"
                    value={@identifier}
                    class="w-full border-2 border-black px-2 py-1.5 font-mono text-sm
                           bg-background focus:outline-none shadow-[2px_2px_0px_#000]
                           placeholder:text-muted-foreground"
                    placeholder={if @has_api_key, do: "NVIDIA", else: "my-ollama"}
                  />
                  <p class="font-mono text-xs text-muted-foreground mt-1">
                    <%= if @has_api_key do %>
                      <%= pgettext("setup help", "Uppercase tag for the API key env var (e.g. NVIDIA → NVIDIA_API_KEY). Also used as the provider key.") %>
                    <% else %>
                      <%= pgettext("setup help", "Used as the provider key. Set one if you plan to add multiple instances of this backend.") %>
                    <% end %>
                  </p>
                </div>

                <%!-- API key (only for presets that require one) --%>
                <%= if @has_api_key do %>
                  <div>
                    <label class="font-mono text-xs text-muted-foreground block mb-1">
                      <%= if @identifier != "" do %>
                        <%= String.upcase(@identifier) %>_API_KEY
                      <% else %>
                        <%= pgettext("setup label", "API Key") %>
                        <span class="opacity-50 ml-1"><%= pgettext("setup label", "(optional)") %></span>
                      <% end %>
                    </label>
                    <input
                      type="password"
                      name="api_key"
                      value={@api_key}
                      class="w-full border-2 border-black px-2 py-1.5 font-mono text-sm
                             bg-background focus:outline-none shadow-[2px_2px_0px_#000]
                             placeholder:text-muted-foreground"
                      placeholder="..."
                    />
                  </div>
                <% end %>
              </form>
            <% end %>
          <% end %>

          <%!-- Free-tier links --%>
          <div class="border-2 border-border p-3 bg-muted space-y-2">
            <p class="font-mono text-xs font-bold">
              <%= pgettext("setup help", "Get started for free") %>
            </p>
            <div class="space-y-1.5">
              <a href="https://build.nvidia.com/" target="_blank"
                 class="block font-mono text-xs hover:underline">
                <span class="font-bold">NVIDIA NIM</span>
                <span class="text-muted-foreground ml-1">— Llama 3.3 70B, Nemotron</span>
              </a>
              <a href="https://console.groq.com/" target="_blank"
                 class="block font-mono text-xs hover:underline">
                <span class="font-bold">Groq</span>
                <span class="text-muted-foreground ml-1">— Fast Llama / Gemma models</span>
              </a>
              <a href="https://aistudio.google.com/" target="_blank"
                 class="block font-mono text-xs hover:underline">
                <span class="font-bold">Google AI Studio</span>
                <span class="text-muted-foreground ml-1">— Gemini 2.5 Flash</span>
              </a>
            </div>
          </div>

        </div>
      <% end %>

      <%= if @sub_step == :model do %>
        <form phx-change="update_model_fields" phx-target={@myself} class="space-y-3">

          <%!-- Configured-provider picker (add_model mode only) --%>
          <%= if @mode == :add_model do %>
            <div>
              <label class="font-mono text-xs text-muted-foreground block mb-1">
                <%= pgettext("setup label", "Provider") %>
              </label>
              <.dropdown
                id="setup-configured-provider"
                name="configured_provider"
                options={Enum.map(@configured_providers, &{&1, &1})}
                selected={@provider_key}
                on_select="select_configured_provider"
                target={@myself}
              />
            </div>
          <% end %>

          <%!-- Model identifier — dropdown for cloud, text input otherwise --%>
          <div>
            <label class="font-mono text-xs text-muted-foreground block mb-1">
              <%= pgettext("setup label", "Model") %>
            </label>
            <%= if @models != [] do %>
              <.dropdown
                id="setup-model"
                name="model"
                options={@models}
                selected={@model_api_id}
                on_select="select_model"
                target={@myself}
              />
            <% else %>
              <input
                type="text"
                name="model_api_id"
                value={@model_api_id}
                class="w-full border-2 border-black px-2 py-1.5 font-mono text-sm
                       bg-background focus:outline-none shadow-[2px_2px_0px_#000]
                       placeholder:text-muted-foreground"
                placeholder="llama3.2"
              />
              <p class="font-mono text-xs text-muted-foreground mt-1">
                <%= pgettext("setup help", "Exact model identifier as it appears in the provider API.") %>
              </p>
            <% end %>
          </div>

          <%!-- Alias --%>
          <div>
            <label class="font-mono text-xs text-muted-foreground block mb-1">
              <%= pgettext("setup label", "Alias") %>
              <span class="opacity-50 ml-1"><%= pgettext("setup label", "(your shorthand for this model)") %></span>
            </label>
            <input
              type="text"
              name="model_alias"
              value={@model_alias}
              class="w-full border-2 border-black px-2 py-1.5 font-mono text-sm
                     bg-background focus:outline-none shadow-[2px_2px_0px_#000]
                     placeholder:text-muted-foreground"
              placeholder={@model_api_id}
            />
          </div>

          <%!-- Set as default + scope --%>
          <div class="flex items-center justify-between gap-4">
            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                checked={@set_default}
                phx-click={JS.push("toggle_default", target: @myself)}
                class="accent-black w-4 h-4"
              />
              <span class="font-mono text-sm">
                <%= pgettext("setup label", "Set as default model") %>
              </span>
            </label>

            <div class="flex-shrink-0">
              <.dropdown
                id="setup-scope"
                name="scope"
                options={scope_options()}
                selected={to_string(@scope)}
                on_select="select_scope"
                target={@myself}
              />
            </div>
          </div>

          <%!-- Parameters (collapsible) --%>
          <div class="border-2 border-black">
            <button type="button"
              phx-click="toggle_params"
              phx-target={@myself}
              class="w-full px-3 py-2 font-mono text-sm font-bold flex items-center
                     justify-between hover:bg-muted">
              <span><%= pgettext("setup label", "Parameters") %></span>
              <span class={["text-xs opacity-50", if(@params_open, do: "rotate-180", else: "")]}>▾</span>
            </button>

            <div class={["p-3 space-y-3 border-t-2 border-black", unless(@params_open, do: "hidden")]}>

              <%!-- Row 1: context_window / max_tokens --%>
              <div class="grid grid-cols-2 gap-2">
                <div>
                  <label class="font-mono text-xs text-muted-foreground flex items-center gap-1 mb-1">
                    <%= pgettext("setup label", "Context window") %>
                    <button type="button" class="border border-black px-1 font-mono text-xs opacity-40 hover:opacity-100 leading-none"
                      title={pgettext("setup help", "Match this to your model's actual context size — e.g. 4096 for most 7B models, 32768 for larger ones. Planck uses it to decide when to summarise the conversation history.")}>?</button>
                  </label>
                  <input type="number" name="param_context_window" value={@param_context_window} min="0" step="1"
                    class="w-full border-2 border-black px-2 py-1.5 font-mono text-sm bg-background focus:outline-none shadow-[2px_2px_0px_#000]"
                    placeholder="e.g. 4096" />
                </div>
                <div>
                  <label class="font-mono text-xs text-muted-foreground flex items-center gap-1 mb-1">
                    <%= pgettext("setup label", "Max output tokens") %>
                    <button type="button" class="border border-black px-1 font-mono text-xs opacity-40 hover:opacity-100 leading-none"
                      title={pgettext("setup help", "Try 2048 for most conversations. Increase to 4096 or more if the model cuts off mid-response on long tasks like writing or code generation.")}>?</button>
                  </label>
                  <input type="number" name="param_max_tokens" value={@param_max_tokens} min="0" step="1"
                    class="w-full border-2 border-black px-2 py-1.5 font-mono text-sm bg-background focus:outline-none shadow-[2px_2px_0px_#000]"
                    placeholder="e.g. 2048" />
                </div>
              </div>

              <%!-- Row 2: temperature / top_k --%>
              <div class="grid grid-cols-2 gap-2">
                <div>
                  <label class="font-mono text-xs text-muted-foreground flex items-center gap-1 mb-1">
                    <%= pgettext("setup label", "Temperature") %>
                    <button type="button" class="border border-black px-1 font-mono text-xs opacity-40 hover:opacity-100 leading-none"
                      title={pgettext("setup help", "Try 0.2 for precise code generation or factual answers. Try 0.7–0.8 for writing tasks. Use 1.0+ for open-ended brainstorming. Higher values may produce incoherent output.")}>?</button>
                  </label>
                  <input type="number" name="param_temperature" value={@param_temperature} min="0" max="2" step="0.1"
                    class="w-full border-2 border-black px-2 py-1.5 font-mono text-sm bg-background focus:outline-none shadow-[2px_2px_0px_#000]"
                    placeholder="1.0" />
                </div>
                <div>
                  <label class="font-mono text-xs text-muted-foreground flex items-center gap-1 mb-1">
                    <%= pgettext("setup label", "Top K") %>
                    <button type="button" class="border border-black px-1 font-mono text-xs opacity-40 hover:opacity-100 leading-none"
                      title={pgettext("setup help", "Try 20 for conservative, on-topic output or 40 for a good balance. Very low values (< 10) may make the model repetitive. Leave at 0 if using Top P instead.")}>?</button>
                  </label>
                  <input type="number" name="param_top_k" value={@param_top_k} min="0" step="1"
                    class="w-full border-2 border-black px-2 py-1.5 font-mono text-sm bg-background focus:outline-none shadow-[2px_2px_0px_#000]"
                    placeholder="0" />
                </div>
              </div>

              <%!-- Row 3: top_p / min_p --%>
              <div class="grid grid-cols-2 gap-2">
                <div>
                  <label class="font-mono text-xs text-muted-foreground flex items-center gap-1 mb-1">
                    <%= pgettext("setup label", "Top P") %>
                    <button type="button" class="border border-black px-1 font-mono text-xs opacity-40 hover:opacity-100 leading-none"
                      title={pgettext("setup help", "Try 0.9 to cut off unlikely words while keeping variety, or 0.5 for more focused output. Leave at 1.0 if using Top K instead.")}>?</button>
                  </label>
                  <input type="number" name="param_top_p" value={@param_top_p} min="0" max="1" step="0.05"
                    class="w-full border-2 border-black px-2 py-1.5 font-mono text-sm bg-background focus:outline-none shadow-[2px_2px_0px_#000]"
                    placeholder="1.0" />
                </div>
                <div>
                  <label class="font-mono text-xs text-muted-foreground flex items-center gap-1 mb-1">
                    <%= pgettext("setup label", "Min P") %>
                    <button type="button" class="border border-black px-1 font-mono text-xs opacity-40 hover:opacity-100 leading-none"
                      title={pgettext("setup help", "Try 0.05 to silently filter out clearly wrong word choices without affecting the overall style. Most models work fine at 0.0 (disabled).")}>?</button>
                  </label>
                  <input type="number" name="param_min_p" value={@param_min_p} min="0" max="1" step="0.01"
                    class="w-full border-2 border-black px-2 py-1.5 font-mono text-sm bg-background focus:outline-none shadow-[2px_2px_0px_#000]"
                    placeholder="0.0" />
                </div>
              </div>

              <%!-- Additional params (JSON) --%>
              <div>
                <label class="font-mono text-xs text-muted-foreground block mb-1">
                  <%= pgettext("setup label", "Additional parameters") %>
                  <span class="opacity-50 ml-1"><%= pgettext("setup label", "(JSON, optional)") %></span>
                </label>
                <textarea
                  name="advanced_opts"
                  rows="3"
                  class="w-full border-2 border-black px-2 py-1.5 font-mono text-xs
                         bg-background focus:outline-none shadow-[2px_2px_0px_#000]
                         placeholder:text-muted-foreground resize-none"
                  placeholder={"{\n  \"receive_timeout\": 600000\n}"}
                ><%= @advanced_opts %></textarea>
              </div>

            </div>
          </div>

        </form>
      <% end %>

      <%= if @error do %>
        <p class="font-mono text-xs text-destructive pt-2"><%= @error %></p>
      <% end %>
    </div>
    """
  end
end
