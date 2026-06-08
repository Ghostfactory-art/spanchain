defmodule SpanChain.Ingestion.RateLimiter do
  @moduledoc "Per-API-key throttle (plug_attack) on /ingest + /v1/traces — flood protection against SQLite write DOS (GF-766)."

  import Plug.Conn
  use PlugAttack

  # GF-785: /health (and /health/) are exempt from throttling — the LB health-check must
  # not get a 429 (otherwise the container is marked dead → deploy restart loop). MUST be the
  # FIRST rule (PlugAttack evaluates in definition order; the first match short-circuits).
  # `if` without else returns nil for other paths → the throttle rule below runs unchanged.
  rule "allow health check", conn do
    if conn.request_path in ["/health", "/health/"], do: allow(true)
  end

  # Throttle per API key — we read the Bearer token directly from the header (AuthPlug
  # does not store it in conn.assigns). AuthPlug runs in the pipeline BEFORE RateLimiter and
  # halts unauthorized requests, so the tokenless branch is purely defensive.
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

  # Test seam: rate_limit_enabled: false (config/test.exs) disables the throttle without
  # depending on ETS timing (flaky failures on rapid repetition). call/2 is
  # defoverridable in PlugAttack; super/2 runs the generated plug_attack_call.
  def call(conn, opts) do
    if Application.get_env(:span_chain, :rate_limit_enabled, true) do
      super(conn, opts)
    else
      conn
    end
  end

  # Over the limit: 429 + JSON + Retry-After (seconds until the window resets; data[:expires_at]
  # is unix time in ms). No raise — only response + halt().
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
