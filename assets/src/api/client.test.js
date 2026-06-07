// GF-795 — apiFetch token validation. Both localStorage and fetch are stubbed via
// vi.stubGlobal (vitest node env has neither), so no jsdom is needed. The invariant
// under test: a network request is never sent with an obviously invalid token.
import { describe, it, expect, vi, afterEach } from 'vitest';
import { apiFetch, UnauthorizedError } from './client';

// Stub localStorage so getItem returns `value`; expose the removeItem spy.
function stubStorage(value) {
  const removeItem = vi.fn();
  vi.stubGlobal('localStorage', {
    getItem: vi.fn(() => value),
    removeItem,
    setItem: vi.fn()
  });
  return { removeItem };
}

function okFetch(body = {}) {
  return vi.fn(() => Promise.resolve({ ok: true, json: () => Promise.resolve(body) }));
}

function statusFetch(status, body = {}) {
  return vi.fn(() => Promise.resolve({ ok: status >= 200 && status < 300, status, json: () => Promise.resolve(body) }));
}

afterEach(() => { vi.unstubAllGlobals(); });

describe('apiFetch token validation (GF-795)', () => {
  it('rejects a 257-char token: removes it and throws, no fetch', async () => {
    const { removeItem } = stubStorage('x'.repeat(257));
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);

    await expect(apiFetch('/runs')).rejects.toThrow('InvalidTokenError');
    expect(removeItem).toHaveBeenCalledWith('gf_token');
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('accepts a 256-char token: fetch proceeds with the Bearer header', async () => {
    const token = 'x'.repeat(256);
    stubStorage(token);
    const fetchMock = okFetch({ runs: [] });
    vi.stubGlobal('fetch', fetchMock);

    await apiFetch('/runs');
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [, opts] = fetchMock.mock.calls[0];
    expect(opts.headers.Authorization).toBe('Bearer ' + token);
  });

  it('null token: fetch proceeds without an Authorization header', async () => {
    stubStorage(null);
    const fetchMock = okFetch({});
    vi.stubGlobal('fetch', fetchMock);

    await apiFetch('/runs');
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [, opts] = fetchMock.mock.calls[0];
    expect(opts.headers.Authorization).toBeUndefined();
  });

  it('rejects a non-string token: removes it and throws, no fetch', async () => {
    // localStorage normally returns string|null; the explicit typeof guard defends
    // against a corrupted store. Stub getItem to return a number to exercise it.
    const { removeItem } = stubStorage(12345);
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);

    await expect(apiFetch('/runs')).rejects.toThrow('InvalidTokenError');
    expect(removeItem).toHaveBeenCalledWith('gf_token');
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

// GF-808 — the 401 handler is passed per-call as options.onUnauthorized (sourced from
// OnUnauthorizedContext by each hook), replacing the old module-level interceptor slot.
describe('apiFetch 401 handling (GF-806/808)', () => {
  it('401 → throws UnauthorizedError', async () => {
    stubStorage('tok');
    vi.stubGlobal('fetch', statusFetch(401));

    await expect(apiFetch('/runs')).rejects.toThrow(UnauthorizedError);
  });

  it('401 → the onUnauthorized option is invoked before the throw', async () => {
    stubStorage('tok');
    vi.stubGlobal('fetch', statusFetch(401));
    const handler = vi.fn();

    await expect(apiFetch('/runs', { onUnauthorized: handler })).rejects.toThrow(UnauthorizedError);
    expect(handler).toHaveBeenCalledTimes(1);
  });

  it('401 → onUnauthorized is NOT forwarded to fetch as a request option', async () => {
    stubStorage('tok');
    const fetchMock = statusFetch(401);
    vi.stubGlobal('fetch', fetchMock);

    await expect(apiFetch('/runs', { onUnauthorized: () => {} })).rejects.toThrow(UnauthorizedError);
    const [, opts] = fetchMock.mock.calls[0];
    expect(opts).not.toHaveProperty('onUnauthorized');
  });

  it('401 without an onUnauthorized option → still throws, no crash (backward compat)', async () => {
    stubStorage('tok');
    vi.stubGlobal('fetch', statusFetch(401));

    // No callback supplied: the typeof guard skips it, and apiFetch still throws.
    await expect(apiFetch('/runs')).rejects.toThrow(UnauthorizedError);
  });

  it('200 → onUnauthorized does not fire (control)', async () => {
    stubStorage('tok');
    vi.stubGlobal('fetch', okFetch({ runs: [] }));
    const handler = vi.fn();

    await expect(apiFetch('/runs', { onUnauthorized: handler })).resolves.toEqual({ runs: [] });
    expect(handler).not.toHaveBeenCalled();
  });
});
