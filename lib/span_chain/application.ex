defmodule SpanChain.Application do
  @moduledoc "Boots Repo, registries, dynamic supervisors, Bandit HTTP, telemetry handlers."

  use Application

  @impl true
  def start(_type, _args) do
    SpanChain.Ingestion.TelemetryLogger.attach()

    children =
      [
        SpanChain.Repo,

        # L0 — existing agent stack
        {Registry, keys: :unique, name: SpanChain.AgentRegistry},
        {DynamicSupervisor, name: SpanChain.AgentSupervisor, strategy: :one_for_one},
        SpanChain.Orchestrator,

        # L1 — ingestion. BufferRegistry lives in the ingest_pipeline sub-supervisor
        # (broadway_children/0), not in the root children — GF-672 rest_for_one.
        {Registry, keys: :unique, name: SpanChain.Ingestion.SessionRegistry},
        SpanChain.Ingestion.SessionSupervisor,

        # L1 — rate limiting (GF-766). ETS storage worker for the plug_attack throttle.
        # MUST run before the HTTP listener (http_children) — the table must exist
        # before the first request. Note: it starts in tests too (the throttle is
        # default-off via :rate_limit_enabled, only the table must exist).
        {PlugAttack.Storage.Ets, name: SpanChain.Ingestion.RateLimiter, clean_period: 60_000},

        # GF-851 — rate limiting for Phoenix port 4001. Separate ETS tables for `/api`
        # (per token) and `/trail` (per IP) → independent buckets, no sharing with port 4000.
        # Same as above: the table must exist before the first request (before the endpoint),
        # and starts in tests too (the throttle is default-off via :rate_limit_enabled).
        {PlugAttack.Storage.Ets, name: SpanChain.Web.RateLimiter.Api, clean_period: 60_000},
        {PlugAttack.Storage.Ets, name: SpanChain.Web.RateLimiter.Trail, clean_period: 60_000},

        # GF-798 — Task.Supervisor for async replay jobs (fire-and-forget; state in the DB
        # table replay_jobs, read via the polling endpoint). Before the web endpoint.
        {Task.Supervisor, name: SpanChain.TaskSupervisor},

        # GF-807/805 — periodic sweeper: stale "running" jobs (task killed without rescue)
        # → "failed"; old completed/failed jobs → deleted (retention). Standalone
        # leaf, Repo-OK. Test env: sweep intervals effectively disabled via config seams.
        SpanChain.Cassettes.ReplayJobSweeper,

        # GF-788 — periodic hash-chain integrity sweep. Queries recent runs, calls
        # verify_ledger/1 per run; :chain_broken → Logger.error + telemetry.
        # Test seam: verify_sweep_interval_ms: :infinity (GenServer runs, no auto-sweep).
        SpanChain.LedgerVerifier
      ] ++ broadway_children() ++ http_children() ++ phoenix_children()

    opts = [strategy: :one_for_one, name: SpanChain.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # GF-667 + GF-672: PipelineSupervisor wraps BufferRegistry + Pipeline under
  # :rest_for_one. Details and the reason for the ordering dependency in that module's @moduledoc
  # (lib/span_chain/ingestion/pipeline_supervisor.ex). GF-739: lifted
  # out of the inline anonymous %{id:..., start:...} block into a clean bootloader in Application.
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
      # GF-783: explicit bind to 0.0.0.0 so the port is reachable from the Docker network
      # (Thousand Island's default is already 0.0.0.0 → dev/test behavior unchanged).
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
