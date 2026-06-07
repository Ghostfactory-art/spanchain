defmodule SpanChain.Ingestion.ValidationPlug do
  @moduledoc "Sanitizuje run_id/agent_id na /ingest boundary — malformed identifikátory dostanou 400 dřív, než dorazí do SGS (GF-767)."

  import Plug.Conn

  @valid_id_regex ~r/^[a-zA-Z0-9_-]{1,128}$/

  def init(opts), do: opts

  # Validace platí jen pro /ingest JSON boundary (čte body_params["run_id"]).
  # /v1/traces nese run_id v resource attributes (NE v body_params), /health a
  # forwardy (/evals, /cassettes) mají vlastní kontrakt — propouštíme beze změny.
  # Stejný path-scoping vzor jako AuthPlug (request_path: "/health").
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
  GF-774: veřejný run_id formát check pro /v1/traces (router.ex). /v1/traces obchází
  `call/2` (path-scoped na /ingest), ale musí použít STEJNÝ kontrakt — deleguje na
  `valid_id?/2` (`:required`), takže regex i nil/non-binary handling jsou single-source.
  """
  def valid_run_id?(run_id), do: valid_id?(run_id, :required)

  # run_id povinné — chybějící i malformed → reject.
  defp valid_id?(nil, :required), do: false
  # agent_id volitelné — chybějící je OK (neměníme API kontrakt).
  defp valid_id?(nil, :optional), do: true
  defp valid_id?(value, _req) when is_binary(value), do: Regex.match?(@valid_id_regex, value)
  # Non-binary hodnota (číslo, mapa, list) regexu nikdy nevyhoví → reject.
  defp valid_id?(_value, _req), do: false

  defp reject(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(%{error: "invalid_id_format"}))
    |> halt()
  end
end
