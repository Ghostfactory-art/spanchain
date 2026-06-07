// GF-822 — loadRuns: the callable fetch worker that both mount and retry() invoke.
// Tested directly (vitest node env, no jsdom / @testing-library) — the hook is not
// rendered; we assert the worker's setState side effects via spy setters, mirroring
// client.test.js (fetch + localStorage stubbed through vi.stubGlobal).
import { describe, it, expect, vi, afterEach } from 'vitest';
import { loadRuns } from './useRuns';

function stubStorage(value) {
  vi.stubGlobal('localStorage', {
    getItem: vi.fn(() => value),
    removeItem: vi.fn(),
    setItem: vi.fn()
  });
}

function okFetch(body = {}) {
  return vi.fn(() => Promise.resolve({ ok: true, json: () => Promise.resolve(body) }));
}

function statusFetch(status, body = {}) {
  return vi.fn(() => Promise.resolve({ ok: status >= 200 && status < 300, status, json: () => Promise.resolve(body) }));
}

function setters() {
  return { setRuns: vi.fn(), setError: vi.fn(), setLoading: vi.fn() };
}

afterEach(() => { vi.unstubAllGlobals(); });

describe('loadRuns (GF-822 retry worker)', () => {
  it('success → sets runs and clears the error (recovery)', async () => {
    stubStorage('tok');
    vi.stubGlobal('fetch', okFetch({ runs: [{ id: 'a' }] }));
    const s = setters();

    await loadRuns(s);

    expect(s.setLoading).toHaveBeenCalledWith(true);
    expect(s.setRuns).toHaveBeenCalledWith([{ id: 'a' }]);
    expect(s.setError).toHaveBeenCalledWith(null);
    expect(s.setLoading).toHaveBeenLastCalledWith(false);
  });

  it('retry re-runs the fetch — invoking the worker again hits the API a second time', async () => {
    stubStorage('tok');
    const fetchMock = okFetch({ runs: [] });
    vi.stubGlobal('fetch', fetchMock);
    const s = setters();

    await loadRuns(s);
    await loadRuns(s);

    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it('non-401 error → sets the error message, does not clear it', async () => {
    stubStorage('tok');
    vi.stubGlobal('fetch', statusFetch(500));
    const s = setters();

    await loadRuns(s);

    expect(s.setError).toHaveBeenCalledWith('API 500: /runs');
    expect(s.setError).not.toHaveBeenCalledWith(null);
    expect(s.setLoading).toHaveBeenLastCalledWith(false);
  });

  it('401 → UnauthorizedError return pattern: no error set (Connect gate owns it)', async () => {
    stubStorage('tok');
    vi.stubGlobal('fetch', statusFetch(401));
    const s = setters();

    await loadRuns(s);

    expect(s.setError).not.toHaveBeenCalled();
    expect(s.setLoading).toHaveBeenLastCalledWith(false);
  });

  it('GF-808 — 401 forwards the worker\'s onUnauthorized through apiFetch', async () => {
    stubStorage('tok');
    vi.stubGlobal('fetch', statusFetch(401));
    const onUnauthorized = vi.fn();

    await loadRuns({ ...setters(), onUnauthorized });

    expect(onUnauthorized).toHaveBeenCalledTimes(1);
  });

  it('GF-829 — pre-aborted signal: finally guard skips setLoading(false) (no post-unmount setState)', async () => {
    stubStorage('tok');
    vi.stubGlobal('fetch', okFetch({ runs: [] }));
    const s = setters();
    const ctrl = new AbortController();
    ctrl.abort();

    await loadRuns({ ...s, signal: ctrl.signal });

    expect(s.setLoading).toHaveBeenCalledWith(true);
    expect(s.setLoading).not.toHaveBeenCalledWith(false); // signal.aborted === true → guarded
  });

  it('GF-829 — fetch rejects with AbortError: catch returns early, no error set', async () => {
    stubStorage('tok');
    vi.stubGlobal('fetch', vi.fn(() => Promise.reject(Object.assign(new Error('aborted'), { name: 'AbortError' }))));
    const s = setters();

    await loadRuns(s);

    expect(s.setError).not.toHaveBeenCalled();
  });
});
