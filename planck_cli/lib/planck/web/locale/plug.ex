defmodule Planck.Web.Locale.Plug do
  @moduledoc """
  Plug for detecting and setting the UI locale.

  Priority order:
  1. `locale` key in `.planck/config.json` or `~/.planck/config.json`
  2. Locale stored in the session (from a previous request)
  3. Browser `Accept-Language` header (or `?locale=` query param)
  4. First entry in `:locales` (fallback)

  Also pushes the resolved locale to the connected sidecar node on every
  call, via `Planck.Headless.Locale.set/1` — the sidecar renders its own
  widget content (e.g. the beads board) with its own `Gettext` backend, on
  a separate node, with no other way to learn which locale to use. See that
  module's moduledoc for why calling it unconditionally on every request is
  fine.

  ## Usage

      plug Planck.Web.Locale.Plug,
        gettext: Planck.Web.Gettext,
        locales: ["en", "es"]
  """

  import Plug.Conn
  alias Planck.Headless.Locale, as: SidecarLocale
  alias Planck.Web.Locale.Config

  @spec init(keyword()) :: Config.t()
  defdelegate init(options), to: Config, as: :new

  @spec call(Plug.Conn.t(), Config.t()) :: Plug.Conn.t()
  def call(%Plug.Conn{} = conn, %Config{} = config) do
    config = Config.select_locale(conn, config)

    Gettext.put_locale(config.gettext, config.selected)

    # Pushed on every request, not just on change — see
    # Planck.Agent.Sidecar.set_locale/1's moduledoc for why the remote side,
    # not this call site, is what makes that cheap. The sidecar renders its
    # own widget content (e.g. the beads board) with its own Gettext
    # backend, and has no other way to know which locale to use — it's a
    # separate node, so it can't just read this process's Gettext locale.
    SidecarLocale.set(config.selected)

    conn
    |> assign(:locale, config.selected)
    |> put_session(:locale, config.selected)
  end
end
