// GF-792a — single fetch wrapper for the Span Chain JSON API (Bearer auth).
// The ONLY place fetch() is called; components reach the API through hooks → apiFetch.
//
// GF-795: the token is read + validated per-call (not at module load — a corrupt
// value must not throw at import, and the read picks up token changes). A stored
// token that is non-string or > 256 chars is removed from localStorage and rejected
// before any network request: an oversized Authorization header otherwise trips
// Bandit's HTTP 431 (Request Header Fields Too Large) before the request reaches
// Elixir, which is a confusing error. No token → no Authorization header (backend
// answers 401). There is no hardcoded dev fallback; the token-input UI lands in
// GF-802. For local dev until then: localStorage.setItem('gf_token', 'dev-secret-change-me').
const GF_API_KEY_MAX_LEN = 256;

// GF-806 — thrown on a 401 so a hook can clear its loading state. The navigation
// response (back to Connect) is the interceptor's job, not the hook's.
export class UnauthorizedError extends Error {
  constructor() {
    super('UnauthorizedError');
    this.name = 'UnauthorizedError';
  }
}

// GF-794: optional `options` (e.g. { method: 'POST' }) spread into fetch — default GET
// behaviour unchanged. On non-2xx, prefer the backend's semantic `error` field
// (e.g. 422 "runs belong to different evals") over the bare status code.
//
// GF-808: the 401 handler is now passed per-call as `options.onUnauthorized` (sourced from
// OnUnauthorizedContext by each hook), replacing the old module-level interceptor slot —
// SSR-safe, no cross-request leak. It is destructured out so it never reaches fetch().
export async function apiFetch(path, options = {}) {
  const { onUnauthorized, ...fetchOptions } = options;
  const raw = localStorage.getItem('gf_token');
  if (raw !== null && (typeof raw !== 'string' || raw.length > GF_API_KEY_MAX_LEN)) {
    localStorage.removeItem('gf_token');
    throw new Error('InvalidTokenError: token removed');
  }

  const res = await fetch('/api' + path, {
    headers: raw === null ? {} : { 'Authorization': 'Bearer ' + raw },
    ...fetchOptions
  });
  if (res.status === 401) {
    if (typeof onUnauthorized === 'function') onUnauthorized(); // informs App → setView('connect')
    throw new UnauthorizedError();                              // lets the calling hook clear its loading state
  }
  if (!res.ok) {
    let msg = 'API ' + res.status + ': ' + path;
    try { const d = await res.json(); if (d.error) msg = d.error; } catch (_) {}
    throw new Error(msg);
  }
  return res.json();
}
