// GF-792a — re-verify a run's ledger on demand (Verify Ledger action in the Dossier).
// Returns a function resolving to a human-readable toast message.
import { useCallback, useContext } from 'react';
import { apiFetch } from '../api/client';
import { OnUnauthorizedContext } from '../context/OnUnauthorizedContext';

export function useVerify() {
  const onUnauthorized = useContext(OnUnauthorizedContext); // GF-808 — 401 still routes to Connect
  return useCallback(async (id) => {
    if (!id) return 'Open a run first.';
    try {
      const data = await apiFetch('/runs/' + encodeURIComponent(id) + '/verify', { onUnauthorized });
      return data.verified === true
        ? 'verify_ledger → OK · ' + data.span_count + '/' + data.span_count + ' spans verified'
        : 'verify_ledger → {:error, :chain_broken}';
    } catch (e) {
      return 'verify_ledger error: ' + e.message;
    }
  }, [onUnauthorized]);
}
