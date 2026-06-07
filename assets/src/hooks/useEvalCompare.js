// GF-794 — run an A/B compare AND load both run skeletons in one shot so CompareTrees
// can render real Exhibit A/B trees (reusing SpanTree) alongside the structural diff.
//
// Promise.all:
//   GET /api/evals/:id/compare?run_a&run_b → {eval_id,run_a,run_b,summary,differences}
//   GET /api/runs/:run_a, GET /api/runs/:run_b → skeletons (normalized like the Dossier)
import { useState, useCallback, useContext } from 'react';
import { apiFetch } from '../api/client';
import { OnUnauthorizedContext } from '../context/OnUnauthorizedContext';
import { normalizeSpans } from './useRun';

export function useEvalCompare() {
  const [result, setResult] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);
  const onUnauthorized = useContext(OnUnauthorizedContext); // GF-808 — 401 still routes to Connect

  const compare = useCallback(async (evalId, runA, runB) => {
    if (!evalId || !runA || !runB) return;
    setLoading(true);
    setError(null);
    try {
      const a = encodeURIComponent(runA);
      const b = encodeURIComponent(runB);
      const [cmp, ra, rb] = await Promise.all([
        apiFetch('/evals/' + encodeURIComponent(evalId) + '/compare?run_a=' + a + '&run_b=' + b, { onUnauthorized }),
        apiFetch('/runs/' + a, { onUnauthorized }),
        apiFetch('/runs/' + b, { onUnauthorized })
      ]);
      // cmp = { eval_id, run_a, run_b, summary, differences } (real Comparator shape)
      setResult({
        ...cmp,
        spansA: normalizeSpans(ra.spans || []),
        spansB: normalizeSpans(rb.spans || [])
      });
    } catch (e) {
      setError(e.message);
      setResult(null);
    } finally {
      setLoading(false);
    }
  }, [onUnauthorized]);

  return { result, loading, error, compare };
}
