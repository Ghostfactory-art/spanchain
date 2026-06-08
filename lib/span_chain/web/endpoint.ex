defmodule SpanChain.Web.Endpoint do
  @moduledoc "Phoenix endpoint for the Trail UI (port 4001). Separate from the Plug /ingest on 4000."

  use Phoenix.Endpoint, otp_app: :span_chain

  @session_options [
    store: :cookie,
    key: "_span_chain_key",
    signing_salt: "gf-trail-cookie",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
  )

  # GF-791/801: serves the static Records Bureau UI from priv/static. Since GF-801,
  # `index.html` is a Vite build output (entry = assets/index.html), as are `app.js`
  # + `app.css` (assets/ → priv/static/). `index.html` is served at `/index.html`,
  # but NOT `/` — the root falls through to the Router's PageController. MUST come before
  # `plug SpanChain.Web.Router`.
  # GF-801: `tokens.css` is NO LONGER in the whitelist — the design tokens are bundled into
  # `app.css` (main.jsx imports src/styles/tokens.css) and no LiveView/React shell
  # links `/tokens.css`. `priv/static/tokens.css` stays tracked on disk, it's just
  # no longer served.
  plug(Plug.Static,
    at: "/",
    from: :span_chain,
    gzip: false,
    only: ~w(index.html app.js app.css),
    # GF-799: cache assets but revalidate via ETag → 304 Not Modified when unchanged.
    # Value is the literal Cache-Control header — Plug.Static's :cache_control_for_etags
    # is a string (not a boolean); a non-binary like `true` falls through to the
    # no-cache clause (Plug.Static.put_cache_header/6) and emits no headers at all.
    cache_control_for_etags: "public, max-age=0, must-revalidate"
  )

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(SpanChain.Web.Router)
end
