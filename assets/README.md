# Span Chain UI — React + Vite frontend (GF-792a)

The React 19 + Vite 8 frontend for the GhostFactory **Span Chain** observability tool.
Phoenix (port 4001) serves the built bundle from `../priv/static/`; there is no separate
production frontend server.

## Commands

```bash
npm install        # install deps
npm run dev        # Vite dev server on :5173, proxies /api + /health → http://localhost:4001
npm run build      # production build → ../priv/static/app.js + app.css
npm run lint       # ESLint
```

## Build contract

- **Entry is `src/main.jsx`**, *not* an HTML file. This is deliberate: the Vite build must
  never overwrite the hand-maintained `../priv/static/index.html` shell (canonical favicon,
  fonts, design tokens).
- `vite.config.js` sets `build.outDir = ../priv/static` with **`emptyOutDir: false`** so the
  build does not wipe the hand-written `tokens.css` and `index.html` already there.
- Output filenames are deterministic (`app.js`, `app.css`) so the Phoenix `Plug.Static`
  whitelist and the shell's `<script>`/`<link>` tags stay stable across builds.

## Layout (`src/`)

- `api/client.js` — **`apiFetch`**, the single `fetch` wrapper (Bearer auth from
  `localStorage.gf_token`; optional `options` arg for POST; surfaces backend `error` JSON).
  **All network access goes through here** — components never call `fetch` directly.
  **GF-806:** exports `UnauthorizedError` + a module-level interceptor slot `setUnauthorizedHandler`;
  any `401` invokes the handler then throws `UnauthorizedError`. `App.jsx` registers a handler once
  (clear token → switch to Connect), so hooks stay navigation-agnostic (no `onAuthError` prop-drilling).
  Covered by 3 of the 7 vitest cases in `client.test.js`.
- `hooks/` — one hook per concern, each calling `apiFetch`:
  `useRuns`, `useRun`, `useSpanPayload`, `useVerify` (GF-792a) and
  `useEvals`, `useEval`, `useEvalCompare`, `useCassettes`, `useReplay` (GF-794).
- `components/` — `masthead/`, `trail/`, `dossier/` (incl. `SpanTree` — builds tree depth
  from `span_id`/`parent_span_id`, GF-793), `evals/` (`Evals` + `CompareTrees`),
  `cassettes/`, `connect/` (**GF-802** — token gate: enter/reveal/connect/disconnect, reads/writes
  `localStorage.gf_token`), `ui/` (Button, Toast, …). `App.jsx` is a small string-keyed view switch
  (no router/Context); its default view is `gf_token ? 'trail' : 'connect'`.
- `lib/format.js` — shared pure formatting helpers.

## Backend API (`/api`, port 4001, Bearer auth, read-only)

`GET /api/runs`, `/api/runs/:run_id` (spans skeleton incl. `span_id`),
`/api/runs/:id/spans/:pk` (full payload), `/api/runs/:id/verify`,
`/api/evals`, `/api/evals/:id`, `GET /api/evals/:id/compare?run_a&run_b` (GF-793),
`/api/cassettes`, `POST /api/cassettes/:id/replay`.

No TypeScript, no extra runtime deps beyond React + Vite.
