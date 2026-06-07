// GF-808 — per-render-tree 401 handler, replacing the module-level interceptor slot that
// used to live in api/client.js (SSR-safe, no cross-request leak). App provides the real
// handler (clear token + route to Connect); the default no-op means apiFetch needs no null
// guard and hooks that render outside a Provider still work.
import { createContext } from 'react';

export const OnUnauthorizedContext = createContext(() => {});
