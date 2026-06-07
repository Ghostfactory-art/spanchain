// GF-830 — abort lifecycle helper shared by the badge hooks (useRuns/useEvals/
// useCassettes). Extracted from retry() so the imperative controller-swap is a pure
// exported function, unit-testable in the vitest node env (no jsdom/RTL) — same
// "thin hook, pure logic" philosophy as the GF-822 loaders.

/**
 * Aborts the current in-flight fetch (if any) and installs a fresh
 * AbortController on the ref. Returns the new signal for the next fetch.
 *
 * Pure — its only effect is mutating the passed ref. Exported for unit testing.
 * @param {{current: AbortController|null}} abortRef - ref holding the live controller
 * @returns {AbortSignal} signal for the freshly-installed controller
 */
export function nextSignal(abortRef) {
  abortRef.current?.abort();
  abortRef.current = new AbortController();
  return abortRef.current.signal;
}
