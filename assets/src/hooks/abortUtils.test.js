// GF-830 — nextSignal: the pure controller-swap behind every badge hook's retry().
// Tested directly (vitest node env, no jsdom / @testing-library) — vi.spyOn on the
// instance is enough; no globalThis AbortController subclass needed. Covers all three
// hooks via the shared helper.
import { describe, it, expect, vi } from 'vitest';
import { nextSignal } from './abortUtils';

describe('nextSignal', () => {
  it('aborts previous controller and returns new signal', () => {
    const abortRef = { current: new AbortController() };
    const previousSignal = abortRef.current.signal;
    const abortSpy = vi.spyOn(abortRef.current, 'abort');

    const newSignal = nextSignal(abortRef);

    expect(abortSpy).toHaveBeenCalledOnce();          // prior in-flight fetch cancelled
    expect(newSignal).not.toBe(previousSignal);       // fresh controller → fresh signal
    expect(abortRef.current.signal).toBe(newSignal);  // ref points at the new controller
  });

  it('handles null/uninitialized ref gracefully', () => {
    const abortRef = { current: null };
    expect(() => nextSignal(abortRef)).not.toThrow(); // ?.abort() guards the null
    expect(abortRef.current).toBeInstanceOf(AbortController);
  });
});
