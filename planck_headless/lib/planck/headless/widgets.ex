defmodule Planck.Headless.Widgets do
  @moduledoc """
  RPC dispatch for sidecar-rendered widgets.

  Mirrors `Planck.Headless.Secrets`'s dispatch shape, but simpler: unlike
  secrets (which can be handled locally via `EnvFile` or remotely via a
  sidecar module), a widget always lives on the sidecar — there is no local
  implementation to fall back to. Every call becomes an `:rpc.call/5` to
  `Planck.Agent.Sidecar` on the connected sidecar node, or the given fallback
  if there is none.

  Every function here is a pass-through: the return value is whatever the
  widget module on the sidecar produced, untouched. See `specs/widgets.md`
  for the full widget design.
  """

  require Logger

  alias Planck.Headless.SidecarManager

  @rpc_timeout_ms 30_000

  @doc "List the sidecar's widgets — the modules paired with its tools via their `:widget` field."
  @spec list() :: [module()]
  def list, do: rpc(:list_widgets, [], [])

  @doc """
  Render a widget by id.

  `myself` is passed through opaquely — see `c:Planck.Agent.Widget.render/1`.
  """
  @spec render(String.t(), term()) :: {:ok, term()} | {:error, term()}
  def render(widget_id, myself) do
    rpc(:widget_render, [widget_id, myself], {:error, :sidecar_not_connected})
  end

  @doc "Dispatch an action to a widget by id."
  @spec dispatch_action(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def dispatch_action(widget_id, action, args) do
    rpc(:widget_action, [widget_id, action, args], {:error, :sidecar_not_connected})
  end

  @doc """
  Return a widget's declared container type by id — see
  `c:Planck.Agent.Widget.container/0`.
  """
  @spec container(String.t()) :: {:ok, Planck.Agent.Widget.container()} | {:error, term()}
  def container(widget_id) do
    rpc(:widget_container, [widget_id], {:error, :sidecar_not_connected})
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec rpc(atom(), [term()], term()) :: term()
  defp rpc(function, args, fallback) do
    case SidecarManager.node() do
      nil ->
        Logger.warning(
          "[Planck.Headless.Widgets] #{function} called but sidecar is not connected"
        )

        fallback

      node ->
        case :rpc.call(node, Planck.Agent.Sidecar, function, args, @rpc_timeout_ms) do
          {:badrpc, reason} ->
            Logger.warning(
              "[Planck.Headless.Widgets] RPC failed (#{function}): #{inspect(reason)}"
            )

            fallback

          result ->
            result
        end
    end
  end
end
