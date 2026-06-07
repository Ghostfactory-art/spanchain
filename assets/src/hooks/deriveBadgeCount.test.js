// GF-816 — deriveBadgeCount: pure nav-badge count derivation behind the Trail/Evals tabs.
// Tested directly (vitest node env, no jsdom / @testing-library) — in→out only, no mount.
import { describe, it, expect } from 'vitest';
import { deriveBadgeCount } from './deriveBadgeCount';

describe('deriveBadgeCount (GF-816)', () => {
  it('empty array, not loading → 0', () => {
    expect(deriveBadgeCount([], false)).toBe(0);
  });

  it('populated array, not loading → length', () => {
    const seven = Array.from({ length: 7 }, (_, i) => ({ id: i }));
    expect(deriveBadgeCount(seven, false)).toBe(7);
  });

  it('loading → null (no badge while fetching)', () => {
    expect(deriveBadgeCount(null, true)).toBe(null);
  });

  it('non-array data, not loading → null (no badge)', () => {
    expect(deriveBadgeCount(undefined, false)).toBe(null);
  });

  // GF-818 — error state
  it('hasError, not loading → "error"', () => {
    expect(deriveBadgeCount(null, false, true)).toBe('error');
  });

  it('loading + hasError → null (loading wins, no error flash on first paint)', () => {
    expect(deriveBadgeCount(null, true, true)).toBe(null);
  });

  it('hasError with populated array → "error" (error wins over data)', () => {
    const seven = Array.from({ length: 7 }, (_, i) => ({ id: i }));
    expect(deriveBadgeCount(seven, false, true)).toBe('error');
  });

  it('hasError=false (default) with populated array → length (backward compat)', () => {
    expect(deriveBadgeCount([{ id: 1 }, { id: 2 }], false, false)).toBe(2);
  });
});
