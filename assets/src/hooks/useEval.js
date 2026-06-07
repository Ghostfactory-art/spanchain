// GF-794 — one eval's detail (the run ids the compare selectors need). The list
// endpoint (/api/evals) carries no runs, so the run options come from here:
// GET /api/evals/:id → {eval:{id,name,status,created_at}, runs:[{run_id,span_count}]}.
import { useState, useEffect, useContext } from 'react';
import { apiFetch } from '../api/client';
import { OnUnauthorizedContext } from '../context/OnUnauthorizedContext';

export function useEval(evalId) {
  const [evalMeta, setEvalMeta] = useState(null);
  const [runs, setRuns] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);
  const onUnauthorized = useContext(OnUnauthorizedContext); // GF-808 — 401 still routes to Connect

  useEffect(() => {
    if (!evalId) { setEvalMeta(null); setRuns([]); return; }

    let cancelled = false;
    setLoading(true);
    setError(null);
    apiFetch('/evals/' + encodeURIComponent(evalId), { onUnauthorized })
      .then(data => {
        if (cancelled) return;
        setEvalMeta(data.eval || null);
        setRuns(data.runs || []);
      })
      .catch(e => { if (!cancelled) setError(e.message); })
      .finally(() => { if (!cancelled) setLoading(false); });

    return () => { cancelled = true; };
  }, [evalId, onUnauthorized]);

  return { evalMeta, runs, loading, error };
}
