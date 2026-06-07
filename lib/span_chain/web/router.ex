defmodule SpanChain.Web.Router do
  @moduledoc "Phoenix router pro Trail UI. Live routes pod /trail."

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    # GF-851: per-IP throttle pro veřejné `/trail` (bez tokenu) — před session/CSRF,
    # ať throttlnutý request nedělá zbytečnou práci.
    plug(SpanChain.Web.RateLimiter)
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SpanChain.Web.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  # GF-789: JSON API pro Span Chain UI (React). Corsica MUSÍ být první — prohlížeč
  # posílá OPTIONS preflight bez Authorization hlavičky, Corsica ho halt-ne s CORS
  # hlavičkami dřív, než se dostane k AuthPlugu (jinak 401 na preflight = app nefunguje).
  pipeline :api do
    plug(Corsica,
      origins: [
        # Vite dev server
        "http://localhost:5173",
        "http://localhost:3000"
      ],
      allow_headers: ["authorization", "content-type"],
      allow_methods: ["GET", "POST", "DELETE", "OPTIONS"],
      max_age: 600
    )

    plug(:accepts, ["json"])
    plug(SpanChain.Ingestion.AuthPlug)
    # GF-851: per-token throttle PO AuthPlugu (neautorizovaný = 401, ne 429).
    plug(SpanChain.Web.RateLimiter)
  end

  scope "/", SpanChain.Web do
    pipe_through(:browser)

    # GF-791: root servíruje statický Records Bureau UI (PageController → send_file).
    # LiveView Trail zůstává na /trail (zachováno).
    get("/", PageController, :index)
    live("/trail", TrailLive, :index)
    live("/trail/:run_id", TrailLive, :detail)
    live("/eval/:eval_id", EvalLive)
  end

  scope "/api", SpanChain.Web do
    pipe_through(:api)

    # Catch-all OPTIONS — Phoenix spustí pipeline plugy jen pro matchnutou route;
    # bez této route by OPTIONS preflight 404nul a Corsica by se nespustil.
    options("/*path", ApiController, :preflight)

    # Runs
    get("/runs", ApiController, :list_runs)
    get("/runs/:run_id", ApiController, :get_run)
    get("/runs/:run_id/spans/:id", ApiController, :get_span)
    get("/runs/:run_id/verify", ApiController, :verify_run)

    # Evals
    get("/evals", ApiController, :list_evals)
    get("/evals/:id", ApiController, :get_eval)
    get("/evals/:id/compare", ApiController, :compare_eval)

    # Cassettes
    get("/cassettes", ApiController, :list_cassettes)
    post("/cassettes/:id/replay", ApiController, :replay_cassette)
    # GF-798: async replay job polling (distinct path segment — no clash with the above).
    get("/cassettes/replay_jobs/:id", ApiController, :get_replay_job)
    # GF-823: cancel an async replay job (same resource as the polling GET).
    delete("/cassettes/replay_jobs/:id", ApiController, :cancel_replay_job)
  end
end
