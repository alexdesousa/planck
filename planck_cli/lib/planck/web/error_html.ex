defmodule Planck.Web.ErrorHTML do
  use Planck.Web, :html

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
