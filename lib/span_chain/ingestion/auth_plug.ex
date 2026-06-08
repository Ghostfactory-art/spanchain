defmodule SpanChain.Ingestion.AuthPlug do
  @moduledoc "Bearer token auth for the /ingest endpoint. /health is always open."

  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(%Plug.Conn{request_path: "/health"} = conn, _opts), do: conn

  def call(conn, _opts) do
    expected = Application.get_env(:span_chain, :api_key)

    # Fail-closed: if config is nil (unconfigured), is_binary fails and the with
    # falls through to else → 401. Without this guard, `Plug.Crypto.secure_compare/2`
    # would raise FunctionClauseError on nil and return 500 (info leak about config state).
    with binary_expected when is_binary(binary_expected) <- expected,
         ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- Plug.Crypto.secure_compare(token, binary_expected) do
      conn
    else
      _ ->
        Logger.warning("GF AuthPlug: unauthorized access attempt to #{conn.request_path}")
        conn |> send_resp(401, "Unauthorized") |> halt()
    end
  end
end
