"""gf.flush() + buffer visibility — silent data loss fix (GF-943).

GF-944: spans are now enqueued rather than sent immediately. Tests that
verify failure → buffer behaviour now call gf.flush() to trigger the send
attempt; assertions on _buffer happen after flush().
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

# _reset_sdk_state is in conftest.py (autouse) — no per-file fixture needed.


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

    # GF-944: span is enqueued, not sent immediately — flush() triggers the send
    with caplog.at_level(logging.WARNING, logger="ghostfactory"):
        async with gf.span("during_outage"):
            pass
        await gf.flush()

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

    # GF-944: flush with backend still down → batch send fails → spans go to buffer
    await gf.flush()
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

    with caplog.at_level(logging.WARNING, logger="ghostfactory"):
        sent = await gf.flush()

    assert sent == 0
    assert _buffer.size() == 1  # re-buffered after failed batch send
    assert any("flush()" in r.message for r in caplog.records)


async def test_flush_empty_buffer_returns_zero():
    gf.init("http://localhost:4000", "test-secret", run_id="idle-run")
    assert await gf.flush() == 0


async def test_flush_without_init_raises_runtime_error():
    # Reset module state (conftest also does this, but be explicit)
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
