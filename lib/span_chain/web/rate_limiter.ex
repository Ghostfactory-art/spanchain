defmodule SpanChain.Web.RateLimiter do
  @moduledoc """
  Throttle for Phoenix port 4001 (`plug_attack`) — flood protection for `/api` (Bearer-gated)
  and the public `/trail` (GF-851). Mirrors the behavior of `Ingestion.RateLimiter` (429 + Retry-After,
  test seam `:rate_limit_enabled`), but with a dual key and separate ETS tables:

    * `:api`     — `["Bearer " <> token]` → throttle per token (storage `#{__MODULE__}.Api`)
    * `:browser` — no token (`/trail`) → throttle per client IP (storage `#{__MODULE__}.Trail`)

  Separate tables keep the `/api` and `/trail` buckets independent (a flood on one doesn't exhaust the other)
  and don't share a bucket with port 4000. The limits mirror port 4000 via the same config keys.

  We don't read the client IP from `conn.remote_ip` (behind the Caddy proxy that's the proxy IP → all visitors
  would share one bucket). Caddy adds `x-forwarded-for` with the real client IP; a local curl
  without the proxy falls back to `conn.remote_ip`. Note: XFF is client-spoofable — a more robust
  solution is `Plug.RemoteIp` (requires a new dependency → Later).
  """

  import Plug.Conn
  use PlugAttack

  @api_storage __MODULE__.Api
  @trail_storage __MODULE__.Trail

  # `:api` (Bearer) → per token; `:browser` (`/trail`, no token) → per client IP.
  rule "throttle api by token, trail by ip", conn do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        throttle({:token, token},
          period: period(),
          limit: limit(),
          storage: {PlugAttack.Storage.Ets, @api_storage}
        )

      _ ->
        throttle({:ip, client_ip(conn)},
          period: period(),
          limit: limit(),
          storage: {PlugAttack.Storage.Ets, @trail_storage}
        )
    end
  end

  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded |> String.split(",") |> List.first() |> String.trim()

      [] ->
        conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defp period, do: Application.get_env(:span_chain, :rate_limit_period_ms, 60_000)
  defp limit, do: Application.get_env(:span_chain, :rate_limit_count, 1_000)

  # Test seam: rate_limit_enabled: false (config/test.exs) disables the throttle without depending
  # on ETS timing. call/2 is defoverridable in PlugAttack; super/2 runs plug_attack_call.
  def call(conn, opts) do
    if Application.get_env(:span_chain, :rate_limit_enabled, true) do
      super(conn, opts)
    else
      conn
    end
  end

  # Over the limit: 429 + JSON + Retry-After (seconds until the window resets; data[:expires_at] is unix
  # time in ms). No raise — only response + halt(). Mirrors Ingestion.RateLimiter.
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
