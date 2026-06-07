defmodule SpanChain.Web.PageController do
  @moduledoc "Serves the static Records Bureau UI (priv/static/index.html) at root (GF-791)."

  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  def index(conn, _params) do
    conn
    |> put_resp_header("content-type", "text/html; charset=utf-8")
    |> send_file(200, Application.app_dir(:span_chain, "priv/static/index.html"))
  end
end
