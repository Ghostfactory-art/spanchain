defmodule SpanChain.Web.Endpoint do
  @moduledoc "Phoenix endpoint pro Trail UI (port 4001). Oddělený od Plug /ingest na 4000."

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

  # GF-791/801: servíruje statický Records Bureau UI z priv/static. Od GF-801 je
  # `index.html` Vite build output (entry = assets/index.html), stejně jako `app.js`
  # + `app.css` (assets/ → priv/static/). `index.html` se servíruje na `/index.html`,
  # ale NE `/` — root propadne do Routeru na PageController. MUSÍ být před
  # `plug SpanChain.Web.Router`.
  # GF-801: `tokens.css` už NENÍ ve whitelistu — design tokeny jsou bundlované do
  # `app.css` (main.jsx importuje src/styles/tokens.css) a žádný LiveView/React shell
  # `/tokens.css` nelinkuje. `priv/static/tokens.css` zůstává tracked na disku, jen se
  # už neservíruje.
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
