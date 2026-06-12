# ADR-005 — SDK Naming: `spanchain` on Both Registries, GhostFactory as Publisher

**Date:** 2026-06-11
**Status:** ACCEPTED (2026-06-11, Jiří Joneš)
**Issue:** GF-947 (Discovery — "Resolve SDK naming + publish to PyPI and npm")
**Author:** Claude (CC CLI session 2026-06-11), for review by Jiří Joneš

---

## Context

The SDKs are the adoption entry point, but today they exist only as local
packages: `pip install ./sdk/python` (`README.public.md`) assumes the customer
has the backend repo cloned next to their agent. Without registry publication,
SDK adoption effectively does not exist.

There is also a naming conflict to settle *before* the first publish (renames
after publish are permanent aliases at best): the backend is branded
**Span Chain** (domain `www.spanchain.dev`, public repo `ghostfactory-art/spanchain`,
LP, README, llms.txt — all post-launch SSoT, Positioning v6.0), while the SDKs
are still named `ghostfactory-sdk` (PyPI-style) and `@ghostfactory/sdk` (npm).

Registry availability, probed 2026-06-11 (HTTP 404 = name free):

| Registry | Name | Status |
|---|---|---|
| PyPI | `spanchain`, `span-chain`, `span-chain-sdk`, `ghostfactory-sdk` | all free |
| npm | `spanchain`, `@spanchain/sdk`, `@span-chain/sdk`, `@ghostfactory/sdk` | all free |

## Decision

**Product name wins. One token, matching the domain and repo slug: `spanchain`.**

1. **PyPI:** distribution **`spanchain`**, import module renamed
   `ghostfactory` → **`spanchain`**. Keep the documented alias
   `import spanchain as gf` so every existing example (`gf.init`, `gf.span`,
   `gf.trace`, `gf.flush`) survives verbatim. Renaming the import module now is
   the whole point of doing this before publish — a dist named `spanchain` that
   you `import ghostfactory` from would be a permanent paper cut.
2. **npm:** **`@spanchain/sdk`** (scoped). Claim the `spanchain` npm org first;
   the scope leaves room for `@spanchain/cli`, `@spanchain/react`, etc. Fallback
   if the org turns out to be unavailable: unscoped `spanchain`.
3. **GhostFactory stays the publisher, not the package name** — `authors` in
   `pyproject.toml`, `author` in `package.json`, "A GhostFactory product" in both
   READMEs. This mirrors how the LP/README already present the relationship.
4. **Version:** publish as **0.1.0** (current). Both SDKs carry MIT (GF-942) and
   `flush()` (GF-943 / TS native). Recommended gate before the actual upload:
   land **GF-944** (Python httpx pooling + batching — a per-span 10 s worst-case
   stall is a bad first impression for the package's first cohort) and ideally
   **GF-892** (TS `trace_id` parity). Naming need not wait on either.
5. **CI/CD:** tag-triggered GitHub Actions — `pypa/gh-action-pypi-publish` with
   PyPI **Trusted Publishing** (OIDC, no long-lived token) and `npm publish
   --provenance`. Tags of the form `sdk-py-v0.1.0` / `sdk-ts-v0.1.0`.
6. **Anti-squat:** register the PyPI name and npm org **now** (0.0.1 placeholder
   or org claim), even before the publish gate above — the names being free
   today is not a durable fact.

### Why `spanchain` and not the alternatives

- `span-chain-sdk` / `@span-chain/sdk`: hyphenation does not match the domain
  (`spanchain.dev`), the repo slug (`spanchain`), or the brand spelling
  ("Span Chain" prose, `spanchain` machine names everywhere else). On PyPI,
  `spanchain` and `span-chain` are *distinct* names — splitting the spelling
  across registries invites typo-squatting and confusion.
- `ghostfactory-sdk` / `@ghostfactory/sdk`: the customer searches for the
  product they read about ("span chain sdk"), not the studio behind it.
  Positioning v6.0 sells Span Chain as the product; the umbrella brand carries
  no search intent yet.
- `-sdk` suffix on PyPI: dropped — `pip install spanchain` is the cleanest
  possible quickstart line, and PyPI has no scoping to justify a suffix.

## Consequences

- Python package dir `ghostfactory/` → `spanchain/`; internal consumers update
  imports (`scripts/compare/shared.ts` is TS; Python-side: `judge.py`,
  `backfill_to_spanchain.py`, smoke tests import `ghostfactory`).
- `README.public.md` quickstart becomes `pip install spanchain` /
  `npm install @spanchain/sdk`; the `./sdk/python` path install remains
  documented as the from-source option.
- Source dirs `ghostfactory-sdk/` / `ghostfactory-ts-sdk/` may keep their names
  (local layout, not customer-facing); renaming them is optional cosmetics and
  intentionally out of scope here.
- New Lane Ready follow-ups: (a) rename + metadata pass, (b) org/name
  registration, (c) publish workflows, (d) README quickstart update.

## Uncertainties (genuine, not resolved here)

- **npm org `spanchain` availability** — the unauthenticated org probe returns
  404 for existing orgs too, so "free" could not be confirmed from here. Must be
  verified by attempting the org claim (step 6) before committing to the scoped
  name; the unscoped `spanchain` package name *was* confirmed free.
- **Where the publish workflow lives** — the SDKs' source of truth is the
  private monorepo; the public repo gets copies via `sync-public.sh` (no
  `.github/workflows` in the copy list). Publishing from the public repo is
  better for provenance/transparency, but requires either adding workflows to
  the copy list or committing them directly in the public repo (which the sync
  script currently treats as fully derived). Needs an explicit call when
  implementing (c).
- **Whether 0.1.0 is feature-complete enough** — flush exists in both SDKs, but
  GF-944 (performance) and GF-733 (TS `setEvalId` module-level last-writer-wins)
  are known, documented gaps. The recommendation above (gate upload on GF-944)
  is a judgment call, not a hard dependency.

---

*ADR-005 · Status: ACCEPTED 2026-06-11 (GF-947) · Naming decision final; publish gated on GF-944 (recommended).*
