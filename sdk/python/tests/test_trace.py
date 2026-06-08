"""Integration tests for @gf.trace + gf.span — OTLP/HTTP JSON /v1/traces (GF-741)."""

import json
import re

import httpx
import pytest
import respx

import ghostfactory as gf


def _first_span(otlp_body: dict) -> dict:
    """Extracts the first span from the OTLP `resourceSpans` envelope."""
    return otlp_body["resourceSpans"][0]["scopeSpans"][0]["spans"][0]


def _resource_attr(otlp_body: dict, key: str) -> str | None:
    attrs = otlp_body["resourceSpans"][0]["resource"]["attributes"]
    for a in attrs:
        if a["key"] == key:
            return a["value"]["stringValue"]
    return None


@respx.mock
async def test_trace_sends_root_span_with_no_parent():
    route = respx.post("http://localhost:4000/v1/traces").mock(
        return_value=httpx.Response(200, json={"partialSuccess": {"rejectedSpans": 0}})
    )
    gf.init("http://localhost:4000", "test-secret", run_id="test-run")

    @gf.trace(name="agent_run")
    async def my_agent():
        return "done"

    result = await my_agent()
    assert result == "done"

    body = json.loads(route.calls[0].request.content)
    assert _resource_attr(body, "service.instance.id") == "test-run"

    span = _first_span(body)
    assert span["name"] == "agent_run"
    # Root span: parentSpanId omitted (not null), per OTLP convention
    assert "parentSpanId" not in span


@respx.mock
async def test_nested_spans_set_parent_via_contextvar():
    calls: list[dict] = []

    def capture(request):
        calls.append(json.loads(request.content))
        return httpx.Response(200, json={"partialSuccess": {"rejectedSpans": 0}})

    respx.post("http://localhost:4000/v1/traces").mock(side_effect=capture)

    gf.init("http://localhost:4000", "test-secret", run_id="nested-test")

    @gf.trace(name="outer")
    async def outer():
        async with gf.span("inner"):
            pass

    await outer()

    assert len(calls) == 2
    spans = [_first_span(c) for c in calls]
    outer_span = next(s for s in spans if s["name"] == "outer")
    inner_span = next(s for s in spans if s["name"] == "inner")

    assert inner_span["parentSpanId"] == outer_span["spanId"]
    assert "parentSpanId" not in outer_span


@respx.mock
async def test_exception_inside_span_sets_error_status_and_reraises():
    calls: list[dict] = []

    def capture(request):
        calls.append(json.loads(request.content))
        return httpx.Response(200, json={"partialSuccess": {"rejectedSpans": 0}})

    respx.post("http://localhost:4000/v1/traces").mock(side_effect=capture)
    gf.init("http://localhost:4000", "test-secret", run_id="err-test")

    with pytest.raises(ValueError, match="boom"):
        async with gf.span("failing_span"):
            raise ValueError("boom")

    assert len(calls) == 1
    span = _first_span(calls[0])
    assert span["name"] == "failing_span"

    # status/error are in attributes (the backend ignores the OTLP `status` field)
    attr_map = {a["key"]: a["value"]["stringValue"] for a in span["attributes"]}
    assert attr_map["status"] == "error"
    assert attr_map["error"] == "boom"


@respx.mock
async def test_root_generates_trace_id_and_child_inherits():
    """GF-884: the root span mints a 128-bit trace_id; the child inherits it
    (one trace_id per run, propagated via the ContextVar)."""
    calls: list[dict] = []

    def capture(request):
        calls.append(json.loads(request.content))
        return httpx.Response(200, json={"partialSuccess": {"rejectedSpans": 0}})

    respx.post("http://localhost:4000/v1/traces").mock(side_effect=capture)
    gf.init("http://localhost:4000", "test-secret", run_id="trace-id-test")

    @gf.trace(name="outer")
    async def outer():
        async with gf.span("inner"):
            pass

    await outer()

    spans = [_first_span(c) for c in calls]
    outer_span = next(s for s in spans if s["name"] == "outer")
    inner_span = next(s for s in spans if s["name"] == "inner")

    assert re.fullmatch(r"[0-9a-f]{32}", outer_span["traceId"])
    assert inner_span["traceId"] == outer_span["traceId"]


@respx.mock
async def test_independent_runs_have_distinct_trace_ids():
    """GF-884: two separate runs (re-init, fresh root) get different trace_ids."""
    calls: list[dict] = []

    def capture(request):
        calls.append(json.loads(request.content))
        return httpx.Response(200, json={"partialSuccess": {"rejectedSpans": 0}})

    respx.post("http://localhost:4000/v1/traces").mock(side_effect=capture)

    @gf.trace(name="run")
    async def run_once():
        pass

    gf.init("http://localhost:4000", "test-secret", run_id="run-a")
    await run_once()
    gf.init("http://localhost:4000", "test-secret", run_id="run-b")
    await run_once()

    trace_ids = [_first_span(c)["traceId"] for c in calls]
    assert len(trace_ids) == 2
    assert trace_ids[0] != trace_ids[1]


async def test_span_without_init_raises_runtime_error():
    # Reset module state
    import ghostfactory as gf_mod

    gf_mod._endpoint = None
    gf_mod._api_key = None

    with pytest.raises(RuntimeError, match="init"):
        async with gf.span("no-init"):
            pass
