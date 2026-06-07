#!/bin/sh
set -e

echo "[GhostFactory] Running database migrations..."
/app/bin/span_chain eval "SpanChain.Release.migrate()"

echo "[GhostFactory] Starting application..."
exec /app/bin/span_chain start
