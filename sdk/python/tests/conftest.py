"""pytest setup. asyncio_mode = "auto" is in pyproject.toml — tests can be plain `async def`."""

import pytest

import ghostfactory as gf
from ghostfactory import _buffer, _context, _exporter


# GF-727: ContextVar isolation between tests. Without this, `set_eval_id`
# in one test could leak into the next (the ContextVar default is
# per-module-load, not per-test). Autouse → always applied.
@pytest.fixture(autouse=True)
def _reset_eval_id_contextvar():
    token = _context._eval_id.set(None)
    try:
        yield
    finally:
        _context._eval_id.reset(token)


# GF-944: Reset module-level SDK state between tests so persistent client +
# background queue do not leak across test boundaries.
@pytest.fixture(autouse=True)
def _reset_sdk_state():
    _do_reset()
    yield
    _do_reset()


def _do_reset():
    if gf._flush_task is not None and not gf._flush_task.done():
        gf._flush_task.cancel()
    gf._endpoint = None
    gf._api_key = None
    gf._pending_queue = None
    gf._flush_task = None
    _exporter._http_client = None
    _buffer._buffer.clear()
