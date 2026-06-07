// GF-804 — getInterval: pure adaptive-backoff schedule behind useReplay's polling loop.
// Tested directly (vitest node env, no jsdom / @testing-library) — importing the module only
// pulls in react/client at load; the hook is never mounted, so in→out assertions suffice.
import { describe, it, expect } from 'vitest';
import { getInterval } from './useReplay';

describe('getInterval (GF-804 adaptive backoff)', () => {
  it('attempt 0 → 1500 (first band)', () => {
    expect(getInterval(0)).toBe(1500);
  });

  it('attempt 4 → 1500 (top edge of first band)', () => {
    expect(getInterval(4)).toBe(1500);
  });

  it('attempt 5 → 3000 (bottom edge of second band)', () => {
    expect(getInterval(5)).toBe(3000);
  });

  it('attempt 14 → 3000 (top edge of second band)', () => {
    expect(getInterval(14)).toBe(3000);
  });

  it('attempt 15 → 5000 (bottom edge of third band)', () => {
    expect(getInterval(15)).toBe(5000);
  });

  it('attempt 100 → 5000 (deep third band)', () => {
    expect(getInterval(100)).toBe(5000);
  });
});
