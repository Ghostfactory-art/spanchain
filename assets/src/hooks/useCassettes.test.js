// GF-814 — normalizeCassettes: pure response-shape normalizer behind useCassettes.
// Tested directly (vitest node env, no jsdom / @testing-library) — the hook itself is
// not rendered; only the pure helper's in→out contract is asserted.
import { describe, it, expect, vi, afterEach } from 'vitest';
import { normalizeCassettes, loadCassettes } from './useCassettes';

describe('normalizeCassettes (GF-814)', () => {
  it('empty object-map response {total:0, cassettes:{}} → {cassettes:[], total:0}', () => {
    expect(normalizeCassettes({ total: 0, cassettes: {} })).toEqual({ cassettes: [], total: 0 });
  });

  it('canonical array response preserves the list and total', () => {
    const data = { cassettes: [{ id: 'a' }], total: 1 };
    expect(normalizeCassettes(data)).toEqual({ cassettes: [{ id: 'a' }], total: 1 });
  });

  it('null → {cassettes:[], total:0}', () => {
    expect(normalizeCassettes(null)).toEqual({ cassettes: [], total: 0 });
  });

  it('undefined → {cassettes:[], total:0}', () => {
    expect(normalizeCassettes(undefined)).toEqual({ cassettes: [], total: 0 });
  });
});

// GF-822 — loadCassettes: the callable fetch worker both mount and retry() invoke.
// Tested directly (vitest node env, no jsdom / RTL), fetch + localStorage stubbed.
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
  return { setCassettes: vi.fn(), setTotal: vi.fn(), setError: vi.fn(), setLoading: vi.fn() };
}

describe('loadCassettes (GF-822 retry worker)', () => {
  afterEach(() => { vi.unstubAllGlobals(); });

  it('success → sets cassettes + total and clears the error (recovery)', async () => {
    stubStorage('tok');
    vi.stubGlobal('fetch', okFetch({ cassettes: [{ id: 'c1' }], total: 1 }));
    const s = setters();

    await loadCassettes(s);

    expect(s.setLoading).toHaveBeenCalledWith(true);
    expect(s.setCassettes).toHaveBeenCalledWith([{ id: 'c1' }]);
    expect(s.setTotal).toHaveBeenCalledWith(1);
    expect(s.setError).toHaveBeenCalledWith(null);
    expect(s.setLoading).toHaveBeenLastCalledWith(false);
  });

  it('retry re-runs the fetch — invoking the worker again hits the API a second time', async () => {
    stubStorage('tok');
    const fetchMock = okFetch({ cassettes: [], total: 0 });
    vi.stubGlobal('fetch', fetchMock);
    const s = setters();

    await loadCassettes(s);
    await loadCassettes(s);

    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it('non-401 error → sets the error message, does not clear it', async () => {
    stubStorage('tok');
    vi.stubGlobal('fetch', statusFetch(500));
    const s = setters();

    await loadCassettes(s);

    expect(s.setError).toHaveBeenCalledWith('API 500: /cassettes');
    expect(s.setError).not.toHaveBeenCalledWith(null);
    expect(s.setLoading).toHaveBeenLastCalledWith(false);
  });

  it('401 → UnauthorizedError return pattern: no error set (Connect gate owns it)', async () => {
    stubStorage('tok');
    vi.stubGlobal('fetch', statusFetch(401));
    const s = setters();

    await loadCassettes(s);

    expect(s.setError).not.toHaveBeenCalled();
    expect(s.setLoading).toHaveBeenLastCalledWith(false);
  });

  it('GF-829 — pre-aborted signal: finally guard skips setLoading(false) (no post-unmount setState)', async () => {
    stubStorage('tok');
    vi.stubGlobal('fetch', okFetch({ cassettes: [], total: 0 }));
    const s = setters();
    const ctrl = new AbortController();
    ctrl.abort();

    await loadCassettes({ ...s, signal: ctrl.signal });

    expect(s.setLoading).toHaveBeenCalledWith(true);
    expect(s.setLoading).not.toHaveBeenCalledWith(false); // signal.aborted === true → guarded
  });

  it('GF-829 — fetch rejects with AbortError: catch returns early, no error set', async () => {
    stubStorage('tok');
    vi.stubGlobal('fetch', vi.fn(() => Promise.reject(Object.assign(new Error('aborted'), { name: 'AbortError' }))));
    const s = setters();

    await loadCassettes(s);

    expect(s.setError).not.toHaveBeenCalled();
  });
});
