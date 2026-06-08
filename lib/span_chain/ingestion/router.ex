defmodule SpanChain.Ingestion.Router do
  @moduledoc "Plug router for the OTLP-style ingestion endpoint POST /ingest."

  use Plug.Router
  require Logger

  alias SpanChain.Ingestion.{
    AuthPlug,
    OtlpTranslator,
    SessionGenServer,
    SessionSupervisor,
    ValidationPlug
  }

  # Auth before parsers: if the token doesn't match, we don't waste CPU parsing a large body.
  plug(AuthPlug)

  # GF-766: per-API-key throttle AFTER AuthPlug (which rejects unauthorized first),
  # BEFORE Plug.Parsers — a blocked client must not burn CPU parsing the JSON body.
  plug(SpanChain.Ingestion.RateLimiter)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  # GF-767: after Plug.Parsers (needs body_params), before :match. Path-scoped to
  # /ingest — rejects malformed run_id/agent_id before it reaches the SGS.
  plug(SpanChain.Ingestion.ValidationPlug)

  plug(:match)
  plug(:dispatch)

  post "/ingest" do
    :telemetry.span([:gf, :ingest, :request], %{}, fn ->
      result = handle_ingest(conn)

      {result.conn,
       %{run_id: result.run_id, span_count: result.span_count, status: result.status}}
    end)
  end

  # GF-649: OTLP/HTTP JSON endpoint. The translator is a dumb adapter; downstream
  # (SGS → Pipeline → Ledger) shares the same path as /ingest.
  post "/v1/traces" do
    :telemetry.span([:gf, :otlp, :request], %{}, fn ->
      result = handle_otlp(conn)

      {result.conn,
       %{run_ids: result.run_ids, span_count: result.span_count, status: result.status}}
    end)
  end

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  # GF-706: Evals domain sub-router. AuthPlug has already run as a pipeline plug
  # (forward receives an authenticated conn). MUST come before the `match _` catch-all.
  forward("/evals", to: SpanChain.Evals.Router)

  # GF-712: Cassettes (Debug Replay VCR). Same pattern as /evals —
  # AuthPlug applies, MUST come before the `match _` catch-all.
  forward("/cassettes", to: SpanChain.Cassettes.Router)

  match _ do
    send_resp(conn, 404, "not found")
  end

  # --------------------------------------------------------------------------

  defp handle_ingest(conn) do
    case validate(conn.body_params) do
      {:ok, run_id, spans} -> do_ingest(conn, run_id, spans)
      {:error, reason} -> respond_error(conn, 400, reason, nil)
    end
  end

  defp do_ingest(conn, run_id, spans) do
    with {:ok, _pid} <- SessionSupervisor.ensure_session(run_id),
         {:ok, _count} <- SessionGenServer.ingest_spans(run_id, spans) do
      conn = put_json_resp(conn, 202, %{accepted: length(spans), run_id: run_id})
      %{conn: conn, run_id: run_id, span_count: length(spans), status: 202}
    else
      {:error, reason} -> respond_error(conn, 500, reason, run_id)
    end
  end

  defp respond_error(conn, status, reason, run_id) do
    conn = put_json_resp(conn, status, %{error: format_error(reason)})
    %{conn: conn, run_id: run_id, span_count: 0, status: status}
  end

  # --------------------------------------------------------------------------
  # OTLP/HTTP handler (GF-649)
  # --------------------------------------------------------------------------

  defp handle_otlp(conn) do
    case OtlpTranslator.translate(conn.body_params) do
      {:ok, groups} ->
        # GF-774: /v1/traces bypasses ValidationPlug (path-scoped to /ingest), so we must
        # validate the run_id from resource.attributes["service.instance.id"] here,
        # with the same regex as /ingest. Malformed (path traversal / >128 / disallowed
        # characters) → reject the WHOLE request (no partial ingest of an injection attempt).
        if Enum.all?(groups, fn {run_id, _ev, _spans} -> ValidationPlug.valid_run_id?(run_id) end) do
          # GF-706: groups is a 3-tuple {run_id, eval_id_or_nil, spans}.
          # GF-727: eval_id goes into the SGS both via ensure_session opts (for the spawn
          # path, init/1 persists it) AND via ingest_spans/3 opts (for an
          # already-running SGS — late-binding in handle_call). Without the second path
          # a second OTLP batch with the same run_id but a new gf.eval_id would lose the
          # association (an existing SGS ignores opts).
          # GF-849: per-group with/else (mirrors /ingest do_ingest/3) — when the SGS returns
          # {:error, reason} (crash/timeout via the ingest_spans try/catch, or a spawn fail
          # in ensure_session), log + continue instead of a bare-match MatchError → 500, which
          # silently dropped spans from the remaining groups. rejectedSpans carries the real count.
          {accepted_ids, accepted_spans, rejected_spans} =
            Enum.reduce(groups, {[], 0, 0}, fn {run_id, eval_id, spans}, {ids, acc, rej} ->
              with {:ok, _pid} <- SessionSupervisor.ensure_session(run_id, eval_id: eval_id),
                   {:ok, _count} <- SessionGenServer.ingest_spans(run_id, spans, eval_id: eval_id) do
                {[run_id | ids], acc + length(spans), rej}
              else
                {:error, reason} ->
                  Logger.error("[OTLP] ingest failed run_id=#{run_id} reason=#{inspect(reason)}")
                  {ids, acc, rej + length(spans)}
              end
            end)

          # OTLP spec: success = 200 (not 202) + a partialSuccess block even for full success.
          conn =
            put_json_resp(conn, 200, %{"partialSuccess" => %{"rejectedSpans" => rejected_spans}})

          %{
            conn: conn,
            run_ids: Enum.reverse(accepted_ids),
            span_count: accepted_spans,
            status: 200
          }
        else
          conn = put_json_resp(conn, 400, %{"error" => "invalid_id_format"})
          %{conn: conn, run_ids: [], span_count: 0, status: 400}
        end

      {:error, :missing_run_id} ->
        msg = "resource attribute 'service.instance.id' is required as run_id"
        conn = put_json_resp(conn, 400, %{"error" => msg})
        %{conn: conn, run_ids: [], span_count: 0, status: 400}
    end
  end

  defp validate(%{"run_id" => run_id, "spans" => spans})
       when is_binary(run_id) and run_id != "" and is_list(spans) and spans != [] do
    if Enum.all?(spans, &is_map/1), do: {:ok, run_id, spans}, else: {:error, :invalid_spans}
  end

  defp validate(%{"run_id" => run_id}) when not is_binary(run_id) or run_id == "",
    do: {:error, :invalid_run_id}

  defp validate(%{"spans" => spans}) when not is_list(spans) or spans == [],
    do: {:error, :invalid_spans}

  defp validate(_), do: {:error, :missing_fields}

  defp put_json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)
end
