defmodule Planck.Web.Live.SetupModal do
  @moduledoc """
  Multi-step modal for first-time provider/model setup and returning-user configuration.

  Thin container LiveComponent. Owns: `step`, `first_run`, `sub_step`,
  `provider_model_mode`. Delegates all business logic to child LiveComponents:

  - `SetupModal.ChooseStep`      — returning-user action picker
  - `SetupModal.ProviderModelStep` — provider + model flow
  - `SetupModal.KeysStep`        — API key management

  Children communicate back via `send_update/2`:
  - `action: :complete`            — save succeeded, notify parent LiveView
  - `action: :cancel`              — go back to :choose step
  - `action: :choose, value: x`    — user picked an action from ChooseStep
  - `action: :sub_step, value: s`  — ProviderModelStep changed its sub-step
  - `action: :saving, value: bool` — ProviderModelStep started/finished saving

  On success sends `:setup_complete` to the parent LiveView.
  """

  use Planck.Web, :live_component

  alias Planck.Headless
  alias Phoenix.LiveView.Socket

  @type step :: :choose | :provider_model | :keys
  @type sub_step :: :provider | :model
  @type provider_model_mode :: :add_provider | :add_model

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  @spec mount(Socket.t()) :: {:ok, Socket.t()}
  def mount(socket) do
    {:ok,
     socket
     |> assign(:step, :choose)
     |> assign(:sub_step, :provider)
     |> assign(:provider_model_mode, :add_provider)
     |> assign(:first_run, false)
     |> assign(:saving, false)
     |> assign(:configured_providers, [])}
  end

  @impl true
  def handle_event(event, params, socket)

  def handle_event("back", _, %{assigns: %{step: :keys}} = socket) do
    {:noreply, assign(socket, :step, :choose)}
  end

  def handle_event("back", _, %{assigns: %{step: :provider_model}} = socket) do
    send_update(Planck.Web.Live.SetupModal.ProviderModelStep,
      id: "provider-model-step",
      action: :go_back
    )

    {:noreply, socket}
  end

  def handle_event("next", _, %{assigns: %{step: :provider_model}} = socket) do
    send_update(Planck.Web.Live.SetupModal.ProviderModelStep,
      id: "provider-model-step",
      action: :next
    )

    {:noreply, socket}
  end

  def handle_event("save", _, %{assigns: %{step: :provider_model}} = socket) do
    send_update(Planck.Web.Live.SetupModal.ProviderModelStep,
      id: "provider-model-step",
      action: :save
    )

    {:noreply, socket}
  end

  @impl true
  @spec update(map(), Socket.t()) :: {:ok, Socket.t()}
  # Messages sent from child components via send_update/2
  def update(%{action: :complete}, socket) do
    send(self(), :setup_complete)
    {:ok, socket}
  end

  def update(%{action: :cancel}, socket) do
    {:ok,
     socket
     |> assign(:step, :choose)
     |> assign(:sub_step, :provider)
     |> assign(:saving, false)}
  end

  def update(%{action: :choose, value: "provider"}, socket) do
    {:ok,
     socket
     |> assign(:step, :provider_model)
     |> assign(:provider_model_mode, :add_provider)
     |> assign(:sub_step, :provider)}
  end

  def update(%{action: :choose, value: "model"}, socket) do
    {:ok,
     socket
     |> assign(:step, :provider_model)
     |> assign(:provider_model_mode, :add_model)
     |> assign(:sub_step, :model)}
  end

  def update(%{action: :choose, value: "keys"}, socket) do
    {:ok, assign(socket, :step, :keys)}
  end

  def update(%{action: :sub_step, value: sub_step}, socket) do
    {:ok, assign(socket, :sub_step, sub_step)}
  end

  def update(%{action: :saving, value: saving}, socket) do
    {:ok, assign(socket, :saving, saving)}
  end

  # Normal assign update from parent LiveView
  def update(assigns, socket) do
    first_run = assigns[:first_run] || false

    configured_providers =
      case Headless.config() do
        %{providers: providers} when is_map(providers) and map_size(providers) > 0 ->
          providers |> Map.keys() |> Enum.sort()

        _ ->
          []
      end

    step = if first_run, do: :provider_model, else: :choose
    provider_model_mode = if first_run, do: :add_provider, else: :add_provider

    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:first_run, first_run)
     |> assign(:step, step)
     |> assign(:sub_step, :provider)
     |> assign(:provider_model_mode, provider_model_mode)
     |> assign(:saving, false)
     |> assign(:configured_providers, configured_providers)}
  end

  # ---------------------------------------------------------------------------
  # Template helpers
  # ---------------------------------------------------------------------------

  @doc false
  @spec step_subtitle(step(), sub_step(), provider_model_mode(), boolean()) :: String.t()
  def step_subtitle(step, sub_step, mode, first_run) do
    two_step? = first_run or mode == :add_provider

    case {step, sub_step} do
      {:choose, _} ->
        pgettext("setup subtitle", "What would you like to configure?")

      {:provider_model, :provider} ->
        if two_step?,
          do: pgettext("setup subtitle", "Step 1 of 2 — Add a provider"),
          else: pgettext("setup subtitle", "Add a provider")

      {:provider_model, :model} ->
        if two_step?,
          do: pgettext("setup subtitle", "Step 2 of 2 — Add a model"),
          else: pgettext("setup subtitle", "Add a model")

      {:keys, _} ->
        pgettext("setup subtitle", "Manage secrets")

      _ ->
        ""
    end
  end
end
