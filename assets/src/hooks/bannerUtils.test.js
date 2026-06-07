// GF-837 — vitest node env (no jsdom/RTL), same convention as abortUtils.test.js.
// Assert on the value, not the implementation.
import { describe, it, expect } from 'vitest';
import { replayBannerMessage } from './bannerUtils';

describe('replayBannerMessage', () => {
  it("'cancelled' → 'zrušeného'", () => {
    expect(replayBannerMessage('cancelled')).toBe('zrušeného');
  });
  it("'failed' → nikdy 'zrušeného'", () => {
    expect(replayBannerMessage('failed')).not.toBe('zrušeného');
  });
  it('neznámý status nehodí', () => {
    expect(() => replayBannerMessage(undefined)).not.toThrow();
  });
});
