// GF-792a — load one run's spans + authoritative verify result for the Dossier, and
// normalize the API span shape into the display shape the sub-panels consume.
//
// GET /api/runs/:id → {run:{run_id,started_at,…}, spans:[{id,seq,event_type,hash,
//   span_id,parent_span_id,started_at,ended_at,status}]}. `id` = integer PK; `hash`
//   is the sha string (4-char prefix is the display id). Since GF-793 the API also
//   returns each span's own `span_id`, so parent→child links resolve and SpanTree can
//   render real hierarchy (see buildDepthMap). Exported for reuse by useEvalCompare.
import { useState, useCallback, useContext } from 'react';
import { apiFetch } from '../api/client';
import { OnUnauthorizedContext } from '../context/OnUnauthorizedContext';
import { durMs } from '../lib/format';

export function normalizeSpans(apiSpans) {
  let prev = 'null';
  return apiSpans.map((s, i) => {
    const hash = String(s.hash || '').slice(0, 4);
    const bad = s.status === 'error';
    const span = {
      pk: s.id,                                  // integer PK for /spans/:pk
      seq: s.seq,
      lv: 'L' + s.seq,
      hash,
      prev,                                      // prev display hash (chain link)
      op: (s.event_type || 'span') + (bad ? ' · error' : ''),
      eventType: s.event_type,
      dur: durMs(s.started_at, s.ended_at),
      ts: s.started_at || '—',
      status: s.status || 'ok',
      bad,
      span_id: s.span_id || null,                // GF-793: own id — parent links resolve
      parent: s.parent_span_id || 'null'
    };
    prev = hash;
    return span;
  });
}

export function useRun() {
  const [runData, setRunData] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);
  const onUnauthorized = useContext(OnUnauthorizedContext); // GF-808 — 401 still routes to Connect

  const loadRun = useCallback(async (id) => {
    setLoading(true);
    setError(null);
    try {
      // Promise.all — autoritativní verify (Island Attack safe).
      const [run, verify] = await Promise.all([
        apiFetch('/runs/' + encodeURIComponent(id), { onUnauthorized }),
        apiFetch('/runs/' + encodeURIComponent(id) + '/verify', { onUnauthorized })
      ]);
      const apiSpans = run.spans || [];
      const spans = normalizeSpans(apiSpans);
      const total = apiSpans.length
        ? durMs(apiSpans[0].started_at, apiSpans[apiSpans.length - 1].ended_at)
        : 0;
      setRunData({
        id,
        started: (run.run && run.run.started_at) || '—',
        spans,
        total,
        pass: verify.verified === true,          // NIKDY neodvozuj z error spanů
        verifiedCount: verify.span_count,
        replayJob: run.replay_job || null        // GF-828: cancelled-replay banner source
      });
    } catch (e) {
      setError(e.message);
      setRunData(null);
    } finally {
      setLoading(false);
    }
  }, [onUnauthorized]);

  return { runData, loading, error, loadRun };
}
