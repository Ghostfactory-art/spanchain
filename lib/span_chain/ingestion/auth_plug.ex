defmodule SpanChain.Ingestion.AuthPlug do
  @moduledoc "Bearer token auth pro /ingest endpoint. /health je vždy volný."

  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(%Plug.Conn{request_path: "/health"} = conn, _opts), do: conn

  def call(conn, _opts) do
    expected = Application.get_env(:span_chain, :api_key)

    # Fail-closed: pokud config je nil (nekonfigurováno), is_binary selže a with
    # propadne do else → 401. Bez tohoto guardu by `Plug.Crypto.secure_compare/2`
    # raisnul FunctionClauseError na nil a vrátil 500 (info leak o stavu configu).
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
