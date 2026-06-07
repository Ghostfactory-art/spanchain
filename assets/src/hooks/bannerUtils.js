// GF-837 — pure helper for the replay-orphan banner text in Dossier. GF-831 widened the
// banner condition from 'cancelled' to 'cancelled' || 'failed' but left the wording as
// "zrušeného" (a user action), which is factually wrong for a failed replay (OOM / crash /
// timeout). Extracted as an exported pure function so the wording is unit-testable in the
// vitest node env (no jsdom/RTL) — same "thin component, pure logic" philosophy as abortUtils.

/**
 * Returns the genitive adjective for the replay-orphan banner, given the replay job status.
 * The preposition "ze" stays valid for both returns ("ze zrušeného" / "ze selhalého").
 *
 * @param {string} status - replay job status ('cancelled' | 'failed' | …)
 * @returns {string} adjective interpolated into the banner text
 */
export function replayBannerMessage(status) {
  if (status === 'failed') return 'selhalého';  // OOM / crash / timeout
  return 'zrušeného';                            // cancelled = uživatelská akce
}
