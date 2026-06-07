// GF-794 — fetch + state for the Cassette library. GET /api/cassettes →
// {cassettes:[{id,run_id,name,recorded_at,inserted_at}]}. No detail endpoint exists,
// so the selected cassette's metadata comes straight from this list (no extra fetch).
import { useState, useEffect, useCallback, useContext, useRef } from 'react';
import { apiFetch, UnauthorizedError } from '../api/client';
import { OnUnauthorizedContext } from '../context/OnUnauthorizedContext';
import { nextSignal } from './abortUtils';

/**
 * Normalize a GET /api/cassettes response into a stable shape for the UI.
 * Accepts the canonical array shape ({cassettes:[…], total:N}) and the defensive
 * object-map shape ({cassettes:{}}); missing/non-numeric total falls back to length.
 * @param {{cassettes?: object[]|object, total?: number}|null|undefined} data - raw API body
 * @returns {{cassettes: object[], total: number}} normalized cassettes list + count
 */
export function normalizeCassettes(data) {
  const raw = data?.cassettes;
  const cassettes = Array.isArray(raw) ? raw : raw ? Object.values(raw) : [];
  const total = typeof data?.total === 'number' && data.total !== null
    ? data.total
    : cassettes.length;
  return { cassettes, total };
}

// GF-822 — callable loader so retry() re-runs the SAME fetch (not a copy). On success
// it clears any stale error, so the Masthead amber chip vanishes once the API recovers.
// GF-808 — onUnauthorized is forwarded to apiFetch so a 401 routes back to Connect.
// GF-829 — signal is an explicit DI param (not a closure on abortRef): it rides apiFetch's
// ...fetchOptions into native fetch, and the finally guard skips setLoading after unmount.
export function loadCassettes({ setCassettes, setTotal, setError, setLoading, onUnauthorized, signal }) {
  setLoading(true);
  return apiFetch('/cassettes', { onUnauthorized, signal })
    .then(data => {
      const norm = normalizeCassettes(data);
      setCassettes(norm.cassettes);
      setTotal(norm.total);
      setError(null);
    })
    .catch(err => {
      if (err.name === 'AbortError') return;        // unmount abort — silently ignore (GF-829)
      if (err instanceof UnauthorizedError) return; // onUnauthorized already fired → Connect gate (GF-806/808/821)
      setError(err.message);
    })
    .finally(() => { if (!signal?.aborted) setLoading(false); }); // no setState post-unmount (GF-829)
}

export function useCassettes() {
  const [cassettes, setCassettes] = useState([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(() => !!localStorage.getItem('gf_token'));
  const [error, setError] = useState(null);
  const onUnauthorized = useContext(OnUnauthorizedContext);
  const abortRef = useRef(null); // GF-829 — controller for the in-flight fetch; aborted on unmount

  // GF-822 — retry() does NOT reset cassettes/total: user keeps stale data, not a blank, until refetch lands.
  // GF-830 — nextSignal aborts the previous in-flight fetch before installing a fresh
  // controller, so a retry mid-flight never orphans the prior request (resource leak).
  const retry = useCallback(() => {
    // No authed fetch without a token (avoids the Connect-screen 401 storm that would wipe a
    // freshly-saved gf_token via App.onUnauthorized → removeItem). Gate here, not before the
    // hooks above — an early return would break Rules of Hooks on the connect transition.
    if (!localStorage.getItem('gf_token')) return; // loading already false from init → nothing to clear
    return loadCassettes({ setCassettes, setTotal, setError, setLoading, onUnauthorized, signal: nextSignal(abortRef) });
  }, [onUnauthorized]);
  useEffect(() => {
    retry();
    return () => abortRef.current?.abort(); // GF-829 — unmount (and retry-change) aborts the in-flight fetch
  }, [retry]);

  return { cassettes, total, loading, error, retry };
}
