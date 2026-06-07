# GF-783 — multi-stage build for the span_chain OTP release.
# Both stages MUST share the same OS family (Debian): an Alpine/musl build copied
# into a Debian/glibc runtime produces an ERTS binary that crashes at boot.

# ── Build stage ───────────────────────────────────────────────────────────────
FROM hexpm/elixir:1.18.4-erlang-27.3.4.12-debian-bookworm-20260518-slim AS build

# build-essential + git for native deps; Node 20 via NodeSource (NOT Debian's apt
# nodejs v18 — Vite 8 requires Node >= 20.19) for `mix assets.deploy`.
RUN apt-get update -y \
  && apt-get install -y build-essential git curl \
  && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
  && apt-get install -y nodejs \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Deps first for layer caching.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

# config/runtime.exs is read at boot; config/*.exs at compile time.
COPY config config
COPY priv priv
COPY lib lib
COPY assets assets

# Vite build → priv/static/. NB: we use `npm install` (not the `mix assets.deploy`
# alias, which runs `npm ci`) because the committed package-lock.json is generated
# on Windows and omits Linux-only optional native deps (e.g. @emnapi/*,
# @rollup/rollup-linux-*) → `npm ci` fails its strict sync check on Linux. These are
# separate RUN steps so an asset-build failure FAILS the image (the alias swallowed
# npm's exit code, which silently shipped an asset-less release).
RUN npm --prefix assets install
RUN npm --prefix assets run build
RUN mix compile
RUN mix release

# ── Runtime stage ───────────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS runtime

# Runtime libs only; curl for the compose healthcheck.
RUN apt-get update -y \
  && apt-get install -y libssl3 libncurses6 openssl curl \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /app/_build/prod/rel/span_chain ./
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

EXPOSE 4000 4001

ENTRYPOINT ["/app/entrypoint.sh"]
