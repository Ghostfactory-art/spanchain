defmodule SpanChain.Web.TrailAuth do
  @moduledoc """
  LiveView on_mount handler for TRAIL_AUTH_ENABLED gate (GF-978, ADR-006).
  Checks session flag set by the :browser pipeline's check_trail_auth plug.
  WebSocket upgrade bypasses Plug pipeline — this on_mount closes the side door.
  """
  import Phoenix.LiveView

  def on_mount(:require_auth, _params, session, socket) do
    if Application.get_env(:span_chain, :trail_auth_enabled, false) do
      case session["trail_authenticated"] do
        true -> {:cont, socket}
        _ -> {:halt, redirect(socket, to: "/trail")}
      end
    else
      {:cont, socket}
    end
  end
end
