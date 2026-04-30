defmodule Planck.Web.Locale.Config do
  @moduledoc "Configuration for the locale plug."

  alias Planck.Web.Locale.Header

  @enforce_keys [:gettext, :locales]
  defstruct [:gettext, :locales, :selected, redirect: false]

  @type t :: %__MODULE__{
          gettext: module(),
          locales: [Header.locale()],
          selected: binary() | nil,
          redirect: boolean()
        }

  @doc "Builds a new config from options. Requires `:gettext` and `:locales`."
  @spec new(keyword()) :: t()
  def new(options) do
    gettext = options[:gettext] || raise ArgumentError, message: "Missing :gettext module"
    locales = options[:locales] || raise ArgumentError, message: "Missing :locales list"

    %__MODULE__{
      redirect: Keyword.get(options, :redirect, false),
      gettext: gettext,
      locales: locales |> Enum.join(",") |> Header.locale()
    }
  end

  @doc "Selects the best locale for the request and stores it in `:selected`."
  @spec select_locale(Plug.Conn.t(), t()) :: t()
  def select_locale(%Plug.Conn{} = conn, %__MODULE__{} = config) do
    %__MODULE__{locales: offered} = config = add_session_locale(conn, config)
    config = add_config_locale(config)

    locale =
      conn
      |> Header.client_locale(offered)
      |> Header.merge(offered)

    %__MODULE__{config | selected: locale}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Prepend session-stored locale so it wins over Accept-Language.
  @spec add_session_locale(Plug.Conn.t(), t()) :: t()
  defp add_session_locale(%Plug.Conn{} = conn, %__MODULE__{locales: offered} = config) do
    locale = get_session_locale(conn)

    if locale in offered,
      do: %__MODULE__{config | locales: Enum.uniq([locale | offered])},
      else: config
  end

  # Prepend the planck_headless config locale (highest priority).
  @spec add_config_locale(t()) :: t()
  defp add_config_locale(%__MODULE__{locales: offered} = config) do
    case Planck.Headless.Config.locale!() do
      locale when is_binary(locale) and locale != "" ->
        parsed = locale |> Header.locale() |> List.first()

        if parsed && parsed in offered do
          %__MODULE__{config | locales: Enum.uniq([parsed | offered])}
        else
          config
        end

      _ ->
        config
    end
  end

  @spec get_session_locale(Plug.Conn.t()) :: Header.locale() | nil
  defp get_session_locale(%Plug.Conn{} = conn) do
    case Plug.Conn.get_session(conn, :locale) do
      locale when is_binary(locale) and locale not in ["", "*"] ->
        locale |> Header.locale() |> List.first()

      _ ->
        nil
    end
  end
end
