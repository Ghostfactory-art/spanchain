defmodule SpanChain.Ingestion.RateLimiter do
  @moduledoc "Per-API-key throttle (plug_attack) na /ingest + /v1/traces — flood ochrana před SQLite write DOS (GF-766)."

  import Plug.Conn
  use PlugAttack

  # GF-785: /health (a /health/) exempt z throttle — LB health-check nesmí dostat
  # 429 (jinak ho označí kontejner za dead → deploy restart loop). MUSÍ být PRVNÍ
  # rule (PlugAttack vyhodnocuje v pořadí definice; první match short-circuits).
  # `if` bez else vrátí nil pro ostatní cesty → throttle rule níže běží beze změny.
  rule "allow health check", conn do
    if conn.request_path in ["/health", "/health/"], do: allow(true)
  end

  # Throttle per API key — Bearer token čteme přímo z hlavičky (AuthPlug ho
  # neukládá do conn.assigns). AuthPlug běží v pipeline PŘED RateLimiterem a
  # halt-ne neautorizované requesty, takže tokenless větev je čistě defenzivní.
  rule "throttle by api key", conn do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        throttle(token,
          period: Application.get_env(:span_chain, :rate_limit_period_ms, 60_000),
          limit: Application.get_env(:span_chain, :rate_limit_count, 1_000),
          storage: {PlugAttack.Storage.Ets, __MODULE__}
        )

      _ ->
        allow(true)
    end
  end

  # Test seam: rate_limit_enabled: false (config/test.exs) vypne throttle bez
  # závislosti na ETS timingu (flaky faily při rychlém opakování). call/2 je
  # v PlugAttack defoverridable; super/2 spustí vygenerovaný plug_attack_call.
  def call(conn, opts) do
    if Application.get_env(:span_chain, :rate_limit_enabled, true) do
      super(conn, opts)
    else
      conn
    end
  end

  # Nad limit: 429 + JSON + Retry-After (sekundy do resetu okna; data[:expires_at]
  # je unix čas v ms). Žádný raise — pouze response + halt().
  def block_action(conn, {:throttle, data}, _opts) do
    retry_after = max(div(data[:expires_at] - System.system_time(:millisecond), 1000), 1)

    conn
    |> put_resp_header("retry-after", to_string(retry_after))
    |> put_resp_content_type("application/json")
    |> send_resp(429, Jason.encode!(%{error: "rate_limit_exceeded"}))
    |> halt()
  end

  def block_action(conn, _data, _opts) do
    conn |> send_resp(403, "Forbidden") |> halt()
  end
end
