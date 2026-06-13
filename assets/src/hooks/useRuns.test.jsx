// @vitest-environment jsdom
// GF-856 — hook-level polling tests: useRuns schedules recursive setTimeout fetches,
// stops on unmount, and continues after a failed tick.
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useRuns } from './useRuns';

function stubStorage(val) {
  vi.stubGlobal('localStorage', {
    getItem: vi.fn(() => val),
    removeItem: vi.fn(),
    setItem: vi.fn(),
  });
}

function okFetch(body = {}) {
  return vi.fn(() =>
    Promise.resolve({ ok: true, json: () => Promise.resolve(body) })
  );
}

// Advance one polling cycle: move timers forward 3 s then flush Promise microtasks
// so the .finally() callback runs and the next setTimeout is scheduled.
const tick = async () => {
  await act(async () => {
    vi.advanceTimersByTime(3000);
    await Promise.resolve();
  });
};

describe('useRuns polling (GF-856)', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    stubStorage('tok');
  });
  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it('polling volá fetch vícekrát — mount + 2 tiky = 3', async () => {
    const fetchMock = okFetch({ runs: [] });
    vi.stubGlobal('fetch', fetchMock);

    renderHook(() => useRuns());
    await tick(); // poll tick 1
    await tick(); // poll tick 2

    expect(fetchMock).toHaveBeenCalledTimes(3); // mount + 2 polls
  });

  it('cleanup zastaví polling — po unmount žádné další volání', async () => {
    const fetchMock = okFetch({ runs: [] });
    vi.stubGlobal('fetch', fetchMock);

    const { unmount } = renderHook(() => useRuns());
    await tick();
    const callsBefore = fetchMock.mock.calls.length;
    unmount();
    await tick();
    await tick();

    expect(fetchMock.mock.calls.length).toBe(callsBefore);
  });

  it('chyba v tiku nezastaví smyčku — druhý tick proběhne', async () => {
    const fetchMock = vi.fn()
      .mockRejectedValueOnce(new Error('network'))
      .mockResolvedValue({ ok: true, json: () => Promise.resolve({ runs: [] }) });
    vi.stubGlobal('fetch', fetchMock);

    renderHook(() => useRuns());
    await tick(); // first tick — fetch rejects; .finally() still schedules next
    await tick(); // second tick — must run

    expect(fetchMock).toHaveBeenCalledTimes(3); // mount + 2 ticks
  });
});
