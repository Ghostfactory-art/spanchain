"""Unit tests for the OTLP payload builder (GF-741) — no HTTP, no server."""

import re
from datetime import datetime, timezone

import pytest

from ghostfactory._exporter import (
    _attr_value,
    _attrs_to_otlp,
    _build_otlp_payload,
    _iso_to_ns,
    _span_to_otlp,
)
from ghostfactory._span import Span


def _make_span(
    span_id: str = "abc123",
    name: str = "llm_call",
    started_at: datetime | None = None,
    ended_at: datetime | None = None,
    parent_span_id: str | None = None,
    attributes: dict | None = None,
) -> Span:
    return Span(
        span_id=span_id,
        name=name,
        run_id="run-otlp-test",
        parent_span_id=parent_span_id,
        started_at=started_at or datetime(2026, 5, 18, 10, 0, 0, tzinfo=timezone.utc),
        ended_at=ended_at or datetime(2026, 5, 18, 10, 0, 1, tzinfo=timezone.utc),
        attributes=attributes or {},
    )


# Test A — payload shape unit test
def test_otlp_payload_shape():
    payload = _build_otlp_payload(
        spans=[_make_span(parent_span_id=None, attributes={"model": "claude"})],
        run_id="run-1",
        eval_id=None,
    )

    rs = payload["resourceSpans"][0]

    # Resource attributes
    keys = {a["key"] for a in rs["resource"]["attributes"]}
    assert "service.instance.id" in keys
    assert "service.name" in keys
    # GF-741: we do NOT use `gf.run_id` — the backend OtlpTranslator reads `service.instance.id`
    assert "gf.run_id" not in keys

    # Span fields
    span = rs["scopeSpans"][0]["spans"][0]
    assert span["spanId"] == "abc123"
    assert "traceId" in span  # GF-884: W3C trace_id now emitted
    assert span["name"] == "llm_call"
    assert "startTimeUnixNano" in span
    assert "endTimeUnixNano" in span
    assert "parentSpanId" not in span  # None → omitted (not null)

    # Attributes — model + auto-merged status="ok"
    attr_keys = {a["key"] for a in span["attributes"]}
    assert "model" in attr_keys
    assert "status" in attr_keys


# Test B — timestamp conversion
def test_iso_to_ns():
    ns = _iso_to_ns("2026-05-18T10:00:00Z")
    # 2026-05-18 10:00:00 UTC = 1_779_098_400 s × 1e9 = 1_779_098_400_000_000_000 ns
    # (The prompt's literal 1747562400000000000 was off-by-one-year; verified via
    # datetime(2026,5,18,10,0,0,tzinfo=utc).timestamp().)
    assert ns == 1_779_098_400_000_000_000
    assert isinstance(ns, int)
    assert len(str(ns)) == 19  # nanoseconds have 19 digits for the year ~2026


def test_iso_to_ns_handles_offset_form():
    # The `+00:00` form (Python datetime.isoformat default) must give the same ns
    assert _iso_to_ns("2026-05-18T10:00:00+00:00") == 1_779_098_400_000_000_000


# Test C — eval_id in resource attributes
def test_eval_id_in_resource_attrs():
    payload = _build_otlp_payload(spans=[], run_id="r1", eval_id="eval-42")

    attrs = payload["resourceSpans"][0]["resource"]["attributes"]
    eval_attr = next(a for a in attrs if a["key"] == "gf.eval_id")
    assert eval_attr["value"]["stringValue"] == "eval-42"


def test_eval_id_none_means_attr_absent():
    payload = _build_otlp_payload(spans=[], run_id="r1", eval_id=None)
    attrs = payload["resourceSpans"][0]["resource"]["attributes"]
    keys = {a["key"] for a in attrs}
    assert "gf.eval_id" not in keys


# Supporting: parent_span_id passthrough + attrs serialization edge cases
def test_parent_span_id_passthrough():
    span_dict = _span_to_otlp(_make_span(parent_span_id="parent-abc"))
    assert span_dict["parentSpanId"] == "parent-abc"


# GF-884: trace_id is emitted as the OTLP `traceId` (W3C 128-bit hex)
def test_span_to_otlp_includes_trace_id():
    span = _make_span()
    span_dict = _span_to_otlp(span)
    assert span_dict["traceId"] == span.trace_id
    assert re.fullmatch(r"[0-9a-f]{32}", span_dict["traceId"])


def test_attrs_to_otlp_type_dispatch():
    # GF-742: type dispatch (drop-in upgrade from the GF-741 string-only contract)
    attrs = _attrs_to_otlp({"model": "claude", "tokens": 128, "ok": True, "cost": 0.003})
    by_key = {a["key"]: a["value"] for a in attrs}
    assert by_key["model"] == {"stringValue": "claude"}
    assert by_key["tokens"] == {"intValue": 128}
    assert by_key["ok"] == {"boolValue": True}
    assert by_key["cost"] == {"doubleValue": 0.003}


@pytest.mark.parametrize(
    "value,expected",
    [
        (42, {"intValue": 42}),
        (True, {"boolValue": True}),
        (False, {"boolValue": False}),
        (3.14, {"doubleValue": 3.14}),
        ("hi", {"stringValue": "hi"}),
        (None, {"stringValue": "None"}),
    ],
)
def test_attr_value_dispatch(value, expected):
    assert _attr_value(value) == expected


def test_attr_value_bool_before_int_guard():
    # Regression: isinstance(True, int) is True. Without the bool-first check,
    # True/False would go as intValue. This test failing ⇒ someone swapped the order.
    assert _attr_value(True) == {"boolValue": True}
    assert _attr_value(False) == {"boolValue": False}
    assert _attr_value(1) == {"intValue": 1}
    assert _attr_value(True) != _attr_value(1)


def test_error_status_merged_into_attributes():
    """Backward-compat with the legacy behavior: status/error in attributes,
    not in the OTLP `status` field (the backend ignores it anyway)."""
    span = _make_span()
    span.status = "error"
    span.error = "boom"

    span_dict = _span_to_otlp(span)
    attr_map = {a["key"]: a["value"]["stringValue"] for a in span_dict["attributes"]}
    assert attr_map["status"] == "error"
    assert attr_map["error"] == "boom"
