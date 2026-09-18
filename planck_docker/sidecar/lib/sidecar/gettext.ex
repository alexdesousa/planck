defmodule Sidecar.Gettext do
  @moduledoc """
  Gettext backend for content the sidecar renders itself (e.g. the beads
  board widget's labels).

  A separate catalog from `Planck.Web.Gettext` (`planck_cli`'s own backend)
  by necessity, not preference: the sidecar runs as a genuinely separate
  distributed Erlang node (see `Planck.Agent.Sidecar.get_locale/0`'s
  moduledoc), so it can't share a Gettext process locale with anything
  running on the `planck_headless`/`planck_cli` side even if the catalogs
  were merged.

  Use this module in a widget module to get `gettext/1`/`pgettext/2` bound to
  it (Gettext 1.0's macro-based API, not the older `import`-based one):

      use Gettext, backend: Sidecar.Gettext

  Translation files live in `priv/gettext/<locale>/LC_MESSAGES/default.po`.
  """
  use Gettext.Backend, otp_app: :sidecar
end
