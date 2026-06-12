"""gf.flush() + buffer visibility — silent data loss fix (GF-943).

Before GF-943, `_buffer.drain()` had no caller: spans buffered after a failed
send stayed there forever (or were FIFO-dropped silently after 1000 items).
These tests pin the new contract: buffering logs a warning, `gf.flush()`
re-sends buffered spans, still-failing spans are re-buffered, FIFO eviction
logs a warning (permanent loss is never silent).
"""

import logging
from collections import deque
from datetime import datetime, timezone

import httpx
import pytest
import respx

import ghostfactory as gf
from ghostfactory import _buffer
from ghostfactory._span import Span

OK_RESPONSE = httpx.Response(200, json={"partialSuccess": {"rejectedSpans": 0}})


@pytest.fixture(autouse=True)
def _clear_buffer():
    """The buffer is module-level state — isolate it between tests."""
    _buffer._buffer.clear()
    yield
    _buffer._buffer.clear()


def _make_span(name: str = "s") -> Span:
    return Span(
        span_id="abc123",
        name=name,
        run_id="run-1",
        parent_span_id=None,
        started_at=datetime.now(timezone.utc),
        ended_at=datetime.now(timezone.utc),
    )


@respx.mock
async def test_failed_send_buffers_span_and_logs_warning(caplog):
    respx.post("http://localhost:4000/v1/traces").mock(
        side_effect=httpx.ConnectError("down")
    )
    gf.init("http://localhost:4000", "test-secret", run_id="outage-run")

    with caplog.at_level(logging.WARNING, logger="ghostfactory"):
        async with gf.span("during_outage"):
            pass

    assert _buffer.size() == 1
    assert any("buffered" in r.message for r in caplog.records)


@respx.mock
async def test_flush_after_outage_sends_buffered_spans():
    route = respx.post("http://localhost:4000/v1/traces").mock(
        side_effect=httpx.ConnectError("down")
    )
    gf.init("http://localhost:4000", "test-secret", run_id="outage-run")

    async with gf.span("first"):
        pass
    async with gf.span("second"):
        pass
    assert _buffer.size() == 2

    # Backend comes back up
    route.mock(return_value=OK_RESPONSE)
    route.side_effect = None

    sent = await gf.flush()

    assert sent == 2
    assert _buffer.size() == 0


@respx.mock
async def test_flush_rebuffers_spans_when_backend_still_down(caplog):
    respx.post("http://localhost:4000/v1/traces").mock(
        side_effect=httpx.ConnectError("still down")
    )
    gf.init("http://localhost:4000", "test-secret", run_id="outage-run")

    async with gf.span("doomed"):
        pass
    assert _buffer.size() == 1

    with caplog.at_level(logging.WARNING, logger="ghostfactory"):
        sent = await gf.flush()

    assert sent == 0
    assert _buffer.size() == 1  # re-buffered, not lost
    assert any("flush()" in r.message for r in caplog.records)


async def test_flush_empty_buffer_returns_zero():
    gf.init("http://localhost:4000", "test-secret", run_id="idle-run")
    assert await gf.flush() == 0


async def test_flush_without_init_raises_runtime_error():
    # Reset module state (same pattern as test_trace.py)
    import ghostfactory as gf_mod

    gf_mod._endpoint = None
    gf_mod._api_key = None

    with pytest.raises(RuntimeError, match="init"):
        await gf.flush()


def test_buffer_eviction_logs_warning(caplog, monkeypatch):
    monkeypatch.setattr(_buffer, "_buffer", deque(maxlen=2))

    with caplog.at_level(logging.WARNING, logger="ghostfactory"):
        _buffer.push(_make_span("oldest"))
        _buffer.push(_make_span("middle"))
        assert not caplog.records  # no eviction yet
        _buffer.push(_make_span("newest"))

    assert _buffer.size() == 2
    assert any(
        "data loss" in r.message and "'oldest'" in r.getMessage()
        for r in caplog.records
    )
