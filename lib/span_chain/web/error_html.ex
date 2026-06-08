defmodule SpanChain.Web.ErrorHTML do
  @moduledoc "Minimal HTML rendering for Phoenix error pages."

  use Phoenix.Component

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
