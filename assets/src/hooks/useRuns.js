// GF-792a — fetch + state for the Trail run list. GET /api/runs → {runs:[…]}.
import { useState, useEffect, useCallback, useContext, useRef } from 'react';
import { apiFetch, UnauthorizedError } from '../api/client';
import { OnUnauthorizedContext } from '../context/OnUnauthorizedContext';
import { nextSignal } from './abortUtils';

// GF-822 — callable loader so retry() re-runs the SAME fetch (not a copy). On success
// it clears any stale error, so the Masthead amber chip vanishes once the API recovers.
// GF-808 — onUnauthorized is forwarded to apiFetch so a 401 routes back to Connect.
// GF-829 — signal is an explicit DI param (not a closure on abortRef): it rides apiFetch's
// ...fetchOptions into native fetch, and the finally guard skips setLoading after unmount.
export function loadRuns({ setRuns, setError, setLoading, onUnauthorized, signal }) {
  setLoading(true);
  return apiFetch('/runs', { onUnauthorized, signal })
    .then(data => { setRuns(data.runs || []); setError(null); })
    .catch(err => {
      if (err.name === 'AbortError') return;        // unmount abort — silently ignore (GF-829)
      if (err instanceof UnauthorizedError) return; // onUnauthorized already fired → Connect gate (GF-806/808/821)
      setError(err.message);
    })
    .finally(() => { if (!signal?.aborted) setLoading(false); }); // no setState post-unmount (GF-829)
}

const POLL_INTERVAL_MS = 3000;

export function useRuns() {
  const [runs, setRuns] = useState([]);
  const [loading, setLoading] = useState(() => !!localStorage.getItem('gf_token'));
  const [error, setError] = useState(null);
  const onUnauthorized = useContext(OnUnauthorizedContext);
  const abortRef = useRef(null); // GF-829 — controller for the in-flight fetch; aborted on unmount

  // GF-822 — retry() does NOT reset runs to null: user keeps stale data, not a blank, until refetch lands.
  // GF-830 — nextSignal aborts the previous in-flight fetch before installing a fresh
  // controller, so a retry mid-flight never orphans the prior request (resource leak).
  const retry = useCallback(() => {
    // No authed fetch without a token. The Connect screen has no gf_token, so firing /api
    // requests there 401s — and the 401 handler (App.onUnauthorized) does removeItem('gf_token'),
    // wiping a token the user is mid-setting. Gate the fetch here (not an early return before the
    // hooks above — that would break Rules of Hooks when the token goes absent→present on connect).
    if (!localStorage.getItem('gf_token')) return; // loading already false from init → nothing to clear
    return loadRuns({ setRuns, setError, setLoading, onUnauthorized, signal: nextSignal(abortRef) });
  }, [onUnauthorized]);
  // GF-856 — recursive setTimeout polling so Trail updates without F5 after OTLP ingest.
  // setTimeout (not setInterval) ensures the next tick never fires before the previous fetch settles.
  // Promise.resolve() wrapper is void-safe: .finally() runs whether retry() returns a Promise or void.
  useEffect(() => {
    let timeoutId;
    let cancelled = false;

    const poll = () => {
      if (cancelled) return;
      Promise.resolve(retry()).finally(() => {
        if (!cancelled) {
          timeoutId = setTimeout(poll, POLL_INTERVAL_MS);
        }
      });
    };

    retry();                                          // mount load (existing behavior)
    timeoutId = setTimeout(poll, POLL_INTERVAL_MS);  // first poll tick after 3 s

    return () => {
      cancelled = true;
      clearTimeout(timeoutId);
      abortRef.current?.abort();                     // GF-829 — unmount aborts in-flight fetch
    };
  }, [retry]);

  return { runs, loading, error, retry };
}
