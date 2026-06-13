"""GF-944: persistent httpx client + batch buffering.

_reset_sdk_state in conftest.py (autouse) resets all state between tests.
"""

import json

import httpx
import pytest
import respx

import ghostfactory as gf
from ghostfactory import _buffer, _exporter

_OK = httpx.Response(200, json={"partialSuccess": {"rejectedSpans": 0}})


async def test_no_client_after_init():
    """After gf.init() only (sync), no httpx client is created — lazy init invariant."""
    gf.init("http://localhost:4000", "k", run_id="r")
    assert _exporter._http_client is None


@respx.mock
async def test_client_created_during_flush():
    """flush() triggers HTTP — proves the client was created lazily during send."""
    respx.post("http://localhost:4000/v1/traces").mock(return_value=_OK)
    gf.init("http://localhost:4000", "k", run_id="r")
    async with gf.span("s"):
        pass
    await gf.flush()
    assert respx.calls.call_count >= 1


@respx.mock
async def test_two_spans_one_http_call():
    """Two spans in the same run → single batch HTTP call with 2 spans in the body."""
    route = respx.post("http://localhost:4000/v1/traces").mock(return_value=_OK)
    gf.init("http://localhost:4000", "k", run_id="batch-run")
    async with gf.span("a"):
        pass
    async with gf.span("b"):
        pass
    await gf.flush()
    assert route.call_count == 1
    body = json.loads(route.calls[0].request.content)
    assert len(body["resourceSpans"][0]["scopeSpans"][0]["spans"]) == 2


@respx.mock
async def test_timeout_no_exception():
    """Backend timeout → SDK never raises to caller (ADR-002-F)."""
    respx.post("http://localhost:4000/v1/traces").mock(
        side_effect=httpx.TimeoutException("boom")
    )
    gf.init("http://localhost:4000", "k", run_id="timeout-run")
    async with gf.span("x"):  # must not raise
        pass
    await gf.flush()  # must not raise


@respx.mock
async def test_flush_lifecycle_clean():
    """flush() closes client and resets task + queue state."""
    respx.post("http://localhost:4000/v1/traces").mock(return_value=_OK)
    gf.init("http://localhost:4000", "k", run_id="lifecycle-run")
    async with gf.span("s"):
        pass
    await gf.flush()
    assert _exporter._http_client is None  # closed by flush()
    assert gf._flush_task is None  # cancelled + reset
    assert gf._pending_queue is None  # reset
