# ADR-008 — Canonical UI Stack: React SPA; LiveView Frozen, Removed After Real-Time Bridge

**Date:** 2026-06-11
**Status:** ACCEPTED (2026-06-11, Jiří Joneš — LiveView freeze effective immediately; real-time bridge = **SSE**, scheduled as its own sprint)
**Issue:** GF-953 (Discovery — "Decide: React SPA vs LiveView — pick canonical UI stack")
**Author:** Claude (CC CLI session 2026-06-11), for review by Jiří Joneš

---

## Context

Two parallel UI layers render the same data:

| | LiveView (`/trail`, `/eval/:id`) | React SPA (`/`, Records Bureau) |
|---|---|---|
| Size | 2 files, ~519 lines | 43 files, ~2 045 lines + 8 test files |
| Data path | direct Repo/PubSub | Bearer-gated `/api` (GF-789) |
| Real-time | PubSub push | polling (deliberate GF-792a choice) |
| Auth | none (GF-950 / ADR-006) | Connect token gate (GF-802) |
| Recent investment | GF-666-era origins, sporadic | ~25+ tickets since GF-792a (hooks, badges, retry, async replay + cancel, banners, design tokens SSoT) |
| Marketing | — | LP screenshots, brand "Records Bureau" aesthetic |

Every feature is paid twice (audit §2.2): GF-828/831 cancelled/failed banner
exists only in React; error counts only in LiveView. Cycle-3 UI tickets
(GF-859/860/861, GF-886) all target the React layer already.

## Decision

**React SPA is canonical. LiveView is frozen immediately and removed once React
has a real-time bridge.**

### 1. React canonical — why

- **Momentum and asymmetric rewrite cost.** Every LiveView feature already has a
  React equivalent (run list → Trail, span tree → Dossier/SpanTree, eval compare
  → Evals view). The reverse is ~2 000 lines plus test infra plus the design
  system. Choosing React deletes 519 lines; choosing LiveView rewrites 2 000+.
- **Customer-stack alignment.** The audience ships AI agents in Python/TS.
  A React UI is forkable/embeddable by that audience; HEEx is not where they
  live. The UI is also a product surface (screenshots on the LP), and the brand
  design system (tokens.css, Records Bureau) is implemented in React.
- **The API boundary earns its keep.** React-over-`/api` keeps the UI honest —
  it can only show what the authenticated public API exposes, which doubles as
  continuous dogfooding of the API customers integrate against. LiveView's
  direct Repo access bypasses that contract.

### 2. LiveView frozen now (not deleted yet)

Freeze = no new features, no parity fixes, bugfixes only if a page errors.
The one capability React lacks is **real-time push** — `/trail` live-tailing a
running agent is a genuinely good demo and the only reason deletion waits.

### 3. Removal gate: real-time bridge for React

`Pipeline.handle_batch` already broadcasts `{:spans_flushed, run_id}` on
PubSub post-commit (GF-703). The bridge is a thin read-only push channel over
the existing broadcast — either a Phoenix Channel on the existing 4001 endpoint
or an SSE endpoint in the `/api` scope (Bearer-gated like the rest), consumed by
the React Trail view to replace/augment polling. Once that lands and the Trail
view live-updates, delete `web/live/*`, the `/trail` + `/eval` routes, and their
`:browser`-pipeline special cases; add redirects `/trail → /` so old links keep
working.

### Rejected alternatives

- **LiveView canonical**: throws away the larger, tested, branded, marketed
  surface to save a JS toolchain the project demonstrably already sustains
  (vitest node-env discipline, GF-822/829/830 hook patterns). Real-time is an
  argument for a *bridge*, not for the whole UI.
- **Permanent hybrid with a "clear boundary"**: the audit shows the boundary
  already eroded twice (banner, error counts) in four weeks with one developer.
  A boundary that needs policing is a boundary that will keep leaking; hybrid
  just makes the double-payment permanent.

## Consequences

- New-feature rule, effective immediately: **UI features land only in React.**
- Cycle-3 UI tickets (GF-859/860/861, GF-886) are unaffected — already React.
- Follow-up issues to file: (a) real-time bridge (Channel-vs-SSE is an
  implementation call inside that ticket), (b) LiveView removal + redirects,
  (c) docs sweep (`development.md`, architecture-map §4, CONTEXT_INDEX rows
  referencing `/trail` LiveView; `docs_test.exs` markers must be re-checked at
  removal time).
- ADR-006 (GF-950 /trail auth gate) is unaffected in either order: the gate
  protects the frozen surface until deletion and dies with it; if the gate
  hasn't been built by removal time, it is simply no longer needed (React's
  data path is already token-gated).
- LP/docs links pointing at `/trail` need the redirect before removal ships.

## Uncertainties (genuine, not resolved here)

- **Maintenance preference vs momentum.** This verdict optimizes for the
  existing investment and the customer stack. If the maintainer's long-term
  preference is an Elixir-only surface (less JS churn for a solo dev), LiveView
  canonical is *defensible* — but it costs a 2 000-line rewrite to get back to
  feature parity, so that preference would need to be strong and explicit.
- **Real-time's actual demo weight.** If live-tailing turns out to matter less
  than assumed (poll interval is seconds), the bridge could be skipped and
  LiveView deleted sooner; if it is the demo centerpiece, the bridge ticket is
  the next UI priority. Needs a product call, not a code call.
- **PubSub→browser fan-out at L3 scale** (many concurrent UI watchers) is
  unexamined; fine at current scale, revisit inside the bridge ticket.

---

*ADR-008 · Status: ACCEPTED 2026-06-11 (GF-953) · New UI features: React only, effective immediately. Bridge variant resolved at acceptance: SSE.*
