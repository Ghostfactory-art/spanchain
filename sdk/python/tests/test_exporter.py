"""HTTP exporter integration tests — OTLP/HTTP JSON on /v1/traces (GF-741).

The pre-GF-741 version tested a custom legacy format; the endpoint and payload shape
changed, the retry/auth/silent-fail contract stays.
"""

import json
from datetime import datetime, timezone

import httpx
import pytest
import respx

from ghostfactory._exporter import send_span
from ghostfactory._span import Span


@pytest.fixture
def sample_span():
    return Span(
        span_id="abc123",
        name="test",
        run_id="run-1",
        parent_span_id=None,
        started_at=datetime.now(timezone.utc),
        ended_at=datetime.now(timezone.utc),
    )


@respx.mock
async def test_send_span_2xx_returns_true_and_uses_bearer_header(sample_span):
    # The backend returns 200 + partialSuccess (OTLP spec), not 202 like the legacy endpoint.
    route = respx.post("http://localhost:4000/v1/traces").mock(
        return_value=httpx.Response(200, json={"partialSuccess": {"rejectedSpans": 0}})
    )

    result = await send_span(sample_span, "http://localhost:4000", "test-secret")

    assert result is True
    assert route.called
    assert route.calls[0].request.headers["authorization"] == "Bearer test-secret"
    assert route.calls[0].request.headers["content-type"] == "application/json"


@respx.mock
async def test_send_span_sends_otlp_resource_spans_envelope(sample_span):
    route = respx.post("http://localhost:4000/v1/traces").mock(
        return_value=httpx.Response(200, json={"partialSuccess": {"rejectedSpans": 0}})
    )

    await send_span(sample_span, "http://localhost:4000", "test-secret")

    body = json.loads(route.calls[0].request.content)
    assert "resourceSpans" in body
    assert "spans" not in body  # GF-741: the legacy flat shape must be gone
    assert "run_id" not in body  # GF-741: run_id is now in resource attrs, not top-level

    resource_attrs = body["resourceSpans"][0]["resource"]["attributes"]
    instance_id = next(a for a in resource_attrs if a["key"] == "service.instance.id")
    assert instance_id["value"]["stringValue"] == "run-1"


@respx.mock
async def test_send_span_500_returns_false_after_retry(sample_span):
    route = respx.post("http://localhost:4000/v1/traces").mock(
        return_value=httpx.Response(500)
    )

    result = await send_span(sample_span, "http://localhost:4000", "test-secret")

    assert result is False
    assert route.call_count == 2  # 1 try + 1 retry


@respx.mock
async def test_send_span_silent_on_network_error(sample_span):
    respx.post("http://localhost:4000/v1/traces").mock(
        side_effect=httpx.ConnectError("down")
    )

    result = await send_span(sample_span, "http://localhost:4000", "test-secret")

    assert result is False  # doesn't crash, just returns False


@respx.mock
async def test_send_span_trailing_slash_in_endpoint(sample_span):
    route = respx.post("http://localhost:4000/v1/traces").mock(
        return_value=httpx.Response(200, json={"partialSuccess": {"rejectedSpans": 0}})
    )

    result = await send_span(sample_span, "http://localhost:4000/", "test-secret")

    assert result is True
    assert route.called
