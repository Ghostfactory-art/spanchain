defmodule SpanChain.Web.RateLimiter do
  @moduledoc """
  Throttle pro Phoenix port 4001 (`plug_attack`) — flood ochrana pro `/api` (Bearer-gated)
  i veřejné `/trail` (GF-851). Zrcadlí chování `Ingestion.RateLimiter` (429 + Retry-After,
  test seam `:rate_limit_enabled`), ale s dvojím klíčem a oddělenými ETS tabulkami:

    * `:api`     — `["Bearer " <> token]` → throttle per token (storage `#{__MODULE__}.Api`)
    * `:browser` — bez tokenu (`/trail`) → throttle per client IP (storage `#{__MODULE__}.Trail`)

  Oddělené tabulky drží `/api` a `/trail` buckety nezávislé (flood na jeden nevyčerpá druhý)
  a nesdílí bucket s portem 4000. Limity zrcadlí port 4000 přes stejné config klíče.

  Client IP nečteme z `conn.remote_ip` (za Caddy proxy je to IP proxy → všichni návštěvníci
  by sdíleli jeden bucket). Caddy přidává `x-forwarded-for` s reálnou client IP; lokální curl
  bez proxy spadne na `conn.remote_ip`. Pozn.: XFF je klientem spoofovatelný — robustnější
  řešení je `Plug.RemoteIp` (vyžaduje novou dependency → Later).
  """

  import Plug.Conn
  use PlugAttack

  @api_storage __MODULE__.Api
  @trail_storage __MODULE__.Trail

  # `:api` (Bearer) → per token; `:browser` (`/trail`, bez tokenu) → per client IP.
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

  # Test seam: rate_limit_enabled: false (config/test.exs) vypne throttle bez závislosti
  # na ETS timingu. call/2 je v PlugAttack defoverridable; super/2 spustí plug_attack_call.
  def call(conn, opts) do
    if Application.get_env(:span_chain, :rate_limit_enabled, true) do
      super(conn, opts)
    else
      conn
    end
  end

  # Nad limit: 429 + JSON + Retry-After (sekundy do resetu okna; data[:expires_at] je unix
  # čas v ms). Žádný raise — pouze response + halt(). Zrcadlí Ingestion.RateLimiter.
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
