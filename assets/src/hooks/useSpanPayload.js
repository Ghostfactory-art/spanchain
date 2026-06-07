// GF-792a — lazily fetch a single span's payload (/runs/:id/spans/:pk) when a span is
// selected in the Dossier. Keeps the fetch in the hook layer so components never call
// apiFetch directly. Payload is untrusted DB content (see PayloadExhibit for handling).
import { useState, useEffect, useContext } from 'react';
import { apiFetch } from '../api/client';
import { OnUnauthorizedContext } from '../context/OnUnauthorizedContext';

export function useSpanPayload(runId, span) {
  const [payload, setPayload] = useState('');
  const [pending, setPending] = useState(false);
  const onUnauthorized = useContext(OnUnauthorizedContext); // GF-808 — 401 still routes to Connect

  useEffect(() => {
    if (!span) { setPayload(''); return; }
    if (span.pk == null || runId == null) { setPayload('{ }'); return; }

    let cancelled = false;
    setPending(true);
    apiFetch('/runs/' + encodeURIComponent(runId) + '/spans/' + encodeURIComponent(span.pk), { onUnauthorized })
      .then(d => { if (!cancelled) setPayload(JSON.stringify(d.payload || {}, null, 2)); })
      .catch(() => { if (!cancelled) setPayload('{ }'); })
      .finally(() => { if (!cancelled) setPending(false); });

    return () => { cancelled = true; };
  }, [runId, span, onUnauthorized]);

  return { payload, pending };
}
