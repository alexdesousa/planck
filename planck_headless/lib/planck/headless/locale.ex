defmodule Planck.Headless.Locale do
  @moduledoc """
  Pushes the resolved UI locale to the connected sidecar node.

  Mirrors `Planck.Headless.Widgets`'s dispatch shape, but one-way and with no
  meaningful fallback value to return — this is a best-effort push, not a
  read a caller is waiting on. `Planck.Web.Locale.Plug` calls `set/1` on
  every request (it has no cheap way to know in advance whether the locale
  actually changed), which is exactly why the remote side
  (`Planck.Agent.Sidecar.set_locale/1`) is written to be a no-op when it
  hasn't.
  """

  require Logger

  alias Planck.Headless.SidecarManager

  @rpc_timeout_ms 5_000

  @doc """
  Tells the sidecar node the current UI locale, if one is connected.

  Always returns `:ok` — a disconnected or slow sidecar shouldn't fail the
  request this is called from.
  """
  @spec set(String.t()) :: :ok
  def set(locale) do
    case SidecarManager.node() do
      nil ->
        :ok

      node ->
        case :rpc.call(node, Planck.Agent.Sidecar, :set_locale, [locale], @rpc_timeout_ms) do
          {:badrpc, reason} ->
            Logger.warning("[Planck.Headless.Locale] RPC failed (set_locale): #{inspect(reason)}")
            :ok

          :ok ->
            :ok
        end
    end
  end
end
