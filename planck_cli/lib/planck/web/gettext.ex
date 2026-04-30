defmodule Planck.Web.Gettext do
  @moduledoc """
  Gettext backend for the Planck Web UI.

  Import this module in templates and components to use `gettext/1`:

      import Planck.Web.Gettext

  Translation files live in `priv/gettext/<locale>/LC_MESSAGES/default.po`.
  """
  use Gettext.Backend, otp_app: :planck_cli
end
