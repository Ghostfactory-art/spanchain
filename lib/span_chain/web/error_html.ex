defmodule SpanChain.Web.ErrorHTML do
  @moduledoc "Minimální HTML rendering pro Phoenix error pages."

  use Phoenix.Component

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
