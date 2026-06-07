// GF-816 — derive a nav-badge count from a hook's array + loading flag. Shared by the
// Trail and Evals tabs (both are array-length counts). Returns null while loading or for
// non-array data → Masthead renders no badge (only when the count is a number).
// GF-818 — third state: a fetch error returns 'error' so Masthead can render a distinct
// chip instead of silently hiding the badge (loading still wins so we don't flash an error
// on the first paint).
export function deriveBadgeCount(data, loading, hasError = false) {
  if (loading) return null;
  if (hasError) return 'error';
  return Array.isArray(data) ? data.length : null;
}
