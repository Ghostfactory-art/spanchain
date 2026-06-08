"""pytest setup. asyncio_mode = "auto" is in pyproject.toml — tests can be plain `async def`."""

import pytest

from ghostfactory import _context


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
