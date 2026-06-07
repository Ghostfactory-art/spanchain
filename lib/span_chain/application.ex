defmodule SpanChain.Application do
  @moduledoc "Boots Repo, registries, dynamic supervisors, Bandit HTTP, telemetry handlers."

  use Application

  @impl true
  def start(_type, _args) do
    SpanChain.Ingestion.TelemetryLogger.attach()

    children =
      [
        SpanChain.Repo,

        # L0 — existující agent stack
        {Registry, keys: :unique, name: SpanChain.AgentRegistry},
        {DynamicSupervisor, name: SpanChain.AgentSupervisor, strategy: :one_for_one},
        SpanChain.Orchestrator,

        # L1 — ingestion. BufferRegistry je v ingest_pipeline sub-supervisoru
        # (broadway_children/0), ne v root children — GF-672 rest_for_one.
        {Registry, keys: :unique, name: SpanChain.Ingestion.SessionRegistry},
        SpanChain.Ingestion.SessionSupervisor,

        # L1 — rate limiting (GF-766). ETS storage worker pro plug_attack throttle.
        # MUSÍ běžet před HTTP listenerem (http_children) — tabulka musí existovat
        # před prvním requestem. Negated: startuje i v testech (throttle je
        # default-off přes :rate_limit_enabled, jen tabulka musí existovat).
        {PlugAttack.Storage.Ets, name: SpanChain.Ingestion.RateLimiter, clean_period: 60_000},

        # GF-851 — rate limiting pro Phoenix port 4001. Oddělené ETS tabulky pro `/api`
        # (per token) a `/trail` (per IP) → nezávislé buckety, žádné sdílení s portem 4000.
        # Stejně jako výše: tabulka musí existovat před prvním requestem (před endpointem),
        # startuje i v testech (throttle je default-off přes :rate_limit_enabled).
        {PlugAttack.Storage.Ets, name: SpanChain.Web.RateLimiter.Api, clean_period: 60_000},
        {PlugAttack.Storage.Ets, name: SpanChain.Web.RateLimiter.Trail, clean_period: 60_000},

        # GF-798 — Task.Supervisor pro async replay jobs (fire-and-forget; stav v DB
        # tabulce replay_jobs, čtený přes polling endpoint). Před web endpointem.
        {Task.Supervisor, name: SpanChain.TaskSupervisor},

        # GF-807/805 — periodic sweeper: stale "running" jobs (task killed bez rescue)
        # → "failed"; staré completed/failed jobs → smazány (retention). Standalone
        # leaf, Repo-OK. Test env: sweep intervaly přes config seamy fakticky vypnuty.
        SpanChain.Cassettes.ReplayJobSweeper
      ] ++ broadway_children() ++ http_children() ++ phoenix_children()

    opts = [strategy: :one_for_one, name: SpanChain.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # GF-667 + GF-672: PipelineSupervisor obaluje BufferRegistry + Pipeline pod
  # :rest_for_one. Detaily a důvod ordering závislosti v @moduledoc tohoto modulu
  # (lib/span_chain/ingestion/pipeline_supervisor.ex). GF-739: vyzvednut
  # z inline anonymous %{id:..., start:...} bloku jako čistý bootloader v Application.
  defp broadway_children do
    if Application.get_env(:span_chain, :start_broadway_pipeline, true) do
      [SpanChain.Ingestion.PipelineSupervisor]
    else
      []
    end
  end

  defp http_children do
    if Application.get_env(:span_chain, :start_http_server, true) do
      port = Application.get_env(:span_chain, :http_port, 4000)
      # GF-783: explicitní bind 0.0.0.0 aby byl port dosažitelný z Docker sítě
      # (Thousand Island default je už 0.0.0.0 → dev/test chování beze změny).
      ip = Application.get_env(:span_chain, :http_bind_ip, {0, 0, 0, 0})
      [{Bandit, plug: SpanChain.Ingestion.Router, port: port, ip: ip}]
    else
      []
    end
  end

  defp phoenix_children do
    if Application.get_env(:span_chain, :start_phoenix_endpoint, true) do
      [
        {Phoenix.PubSub, name: SpanChain.PubSub},
        SpanChain.Web.Endpoint
      ]
    else
      []
    end
  end
end
