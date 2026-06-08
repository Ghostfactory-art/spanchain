defmodule SpanChain.Ingestion.ValidationPlug do
  @moduledoc "Sanitizes run_id/agent_id at the /ingest boundary — malformed identifiers get a 400 before they reach the SGS (GF-767)."

  import Plug.Conn

  @valid_id_regex ~r/^[a-zA-Z0-9_-]{1,128}$/

  def init(opts), do: opts

  # Validation applies only to the /ingest JSON boundary (reads body_params["run_id"]).
  # /v1/traces carries run_id in resource attributes (NOT in body_params), and /health and
  # the forwards (/evals, /cassettes) have their own contract — we pass them through unchanged.
  # Same path-scoping pattern as AuthPlug (request_path: "/health").
  def call(%Plug.Conn{request_path: "/ingest"} = conn, _opts) do
    if valid_id?(conn.body_params["run_id"], :required) and
         valid_id?(conn.body_params["agent_id"], :optional) do
      conn
    else
      reject(conn)
    end
  end

  def call(conn, _opts), do: conn

  @doc """
  GF-774: public run_id format check for /v1/traces (router.ex). /v1/traces bypasses
  `call/2` (path-scoped to /ingest), but must use the SAME contract — delegates to
  `valid_id?/2` (`:required`), so the regex and nil/non-binary handling are single-source.
  """
  def valid_run_id?(run_id), do: valid_id?(run_id, :required)

  # run_id is required — both missing and malformed → reject.
  defp valid_id?(nil, :required), do: false
  # agent_id is optional — missing is OK (we don't change the API contract).
  defp valid_id?(nil, :optional), do: true
  defp valid_id?(value, _req) when is_binary(value), do: Regex.match?(@valid_id_regex, value)
  # A non-binary value (number, map, list) never matches the regex → reject.
  defp valid_id?(_value, _req), do: false

  defp reject(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(%{error: "invalid_id_format"}))
    |> halt()
  end
end
