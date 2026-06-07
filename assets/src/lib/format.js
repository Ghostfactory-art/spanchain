// GF-792a — shared formatting helpers ported verbatim from priv/static/index.html
// (GF-791). Pure functions used by Trail + Dossier; keep render logic out of components.

// Run status → stamp CSS class + display text.
export const STAMP = { ok: 'ver', bad: 'brk', live: 'live', replay: 'rep' };
export const STAMPTX = { ok: 'Verified', bad: 'Chain broken', live: 'In session', replay: 'Replay' };

const STATUSMAP = {
  ok: 'ok', verified: 'ok', valid: 'ok',
  bad: 'bad', broken: 'bad', error: 'bad',
  live: 'live', running: 'live',
  replay: 'replay'
};

export function normStatus(s) {
  return STATUSMAP[String(s || '').toLowerCase()] || 'ok';
}

// /runs list shape: {run_id, status, started_at, span_count, error_count}.
// Live runs can't be detected without a WebSocket, so error_count drives bad/ok.
export function runStatus(r) {
  if (r.error_count > 0) return 'bad';
  return normStatus(r.status);
}

export function fmtTime(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  if (isNaN(d)) return String(iso).slice(11, 19) || '—';
  return d.toTimeString().slice(0, 8);
}

export function durMs(start, end) {
  if (!start || !end) return 0;
  const ms = new Date(end) - new Date(start);
  return (isNaN(ms) || ms < 0) ? 0 : ms;
}

// Retained for parity with the original (GF-791). React escapes text children, so
// payload rendering does not call this — it is the canonical escaper if any code
// ever needs to build raw markup from untrusted content.
export function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
