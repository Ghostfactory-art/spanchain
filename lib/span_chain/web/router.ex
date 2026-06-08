defmodule SpanChain.Web.Router do
  @moduledoc "Phoenix router for the Trail UI. Live routes under /trail."

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    # GF-851: per-IP throttle for the public `/trail` (no token) — before session/CSRF,
    # so a throttled request doesn't do needless work.
    plug(SpanChain.Web.RateLimiter)
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SpanChain.Web.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  # GF-789: JSON API for the Span Chain UI (React). Corsica MUST be first — the browser
  # sends an OPTIONS preflight without an Authorization header, and Corsica halts it with CORS
  # headers before it reaches AuthPlug (otherwise a 401 on the preflight = the app doesn't work).
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
    # GF-851: per-token throttle AFTER AuthPlug (unauthorized = 401, not 429).
    plug(SpanChain.Web.RateLimiter)
  end

  scope "/", SpanChain.Web do
    pipe_through(:browser)

    # GF-791: the root serves the static Records Bureau UI (PageController → send_file).
    # The LiveView Trail stays at /trail (preserved).
    get("/", PageController, :index)
    live("/trail", TrailLive, :index)
    live("/trail/:run_id", TrailLive, :detail)
    live("/eval/:eval_id", EvalLive)
  end

  scope "/api", SpanChain.Web do
    pipe_through(:api)

    # Catch-all OPTIONS — Phoenix runs the pipeline plugs only for a matched route;
    # without this route the OPTIONS preflight would 404 and Corsica wouldn't run.
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
