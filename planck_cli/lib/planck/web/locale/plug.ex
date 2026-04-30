defmodule Planck.Web.Locale.Plug do
  @moduledoc """
  Plug for detecting and setting the UI locale.

  Priority order:
  1. `locale` key in `.planck/config.json` or `~/.planck/config.json`
  2. Locale stored in the session (from a previous request)
  3. Browser `Accept-Language` header (or `?locale=` query param)
  4. First entry in `:locales` (fallback)

  ## Usage

      plug Planck.Web.Locale.Plug,
        gettext: Planck.Web.Gettext,
        locales: ["en", "es"]
  """

  import Plug.Conn
  alias Planck.Web.Locale.Config

  @spec init(keyword()) :: Config.t()
  defdelegate init(options), to: Config, as: :new

  @spec call(Plug.Conn.t(), Config.t()) :: Plug.Conn.t()
  def call(%Plug.Conn{} = conn, %Config{} = config) do
    config = Config.select_locale(conn, config)

    Gettext.put_locale(config.gettext, config.selected)

    conn
    |> assign(:locale, config.selected)
    |> put_session(:locale, config.selected)
  end
end
