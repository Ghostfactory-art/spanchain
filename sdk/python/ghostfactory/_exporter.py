"""HTTP exporter — POST /v1/traces (OTLP/HTTP JSON, GF-741).

The public `send_span` function keeps its signature — internally it builds the OTLP
`ResourceSpans` envelope around a single-span batch. The public API
(`gf.init`/`@gf.trace`/`gf.span`) in `__init__.py` is untouched.

## Field mapping (Python Span → OTLP)

| Python (`_span.Span`)      | OTLP JSON                                        |
| -------------------------- | ------------------------------------------------ |
| `span.run_id`              | `resource.attributes["service.instance.id"]`*    |
| `span.trace_id`            | `traceId` (W3C 128-bit hex, GF-884)              |
| `span.span_id`             | `spanId`                                         |
| `span.name`                | `name`                                           |
| `span.parent_span_id`      | `parentSpanId` (omitted if `None`)               |
| `span.started_at`          | `startTimeUnixNano` (str, ns since epoch)        |
| `span.ended_at`            | `endTimeUnixNano` (str, ns since epoch)          |
| `span.attributes`          | `attributes` (KeyValue array, stringValue only)  |
| `span.status`/`span.error` | merged into `attributes` (the backend ignores the OTLP status) |

*`service.instance.id` is the required canonical OTel key for `run_id` —
the backend `OtlpTranslator.extract_run_id/1` reads exactly this attribute. The TS SDK
(GF-730) uses the same mapping.

## What the backend ignores (= we don't map)
`kind`, `events`, `links`, `traceState`, the OTLP `status` field,
`doubleValue`/`arrayValue`/`kvlistValue`. See the `otlp_translator.ex` @moduledoc.
`traceId` IS now emitted (GF-884) for W3C/OTel interop, but the backend still ignores it
for chain integrity — run_id comes from `service.instance.id`, linkage from `prev_hash`.
"""

import logging
from datetime import datetime, timezone
from typing import Any

import httpx

from . import _context
from ._span import Span, _iso_z

logger = logging.getLogger("ghostfactory")


def _iso_to_ns(iso_str: str) -> int:
    """ISO 8601 string → Unix nanoseconds (int).

    Always tz-aware: a trailing `Z` is normalized to `+00:00`; naive input is treated
    as UTC (defensive — the Span dataclass requires tz-aware, but this callable is
    public-ish).
    """
    dt = datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp() * 1_000_000_000)


def _attr_value(v: object) -> dict:
    """GF-742: type dispatch for a single OTLP attribute value.

    The check order is critical — `isinstance(True, int) is True` in Python,
    so `bool` MUST come before `int`, otherwise `True` would go as `intValue: 1`.
    """
    if isinstance(v, bool):
        return {"boolValue": v}
    if isinstance(v, int):
        return {"intValue": v}
    if isinstance(v, float):
        return {"doubleValue": v}
    return {"stringValue": str(v)}


def _attrs_to_otlp(attrs: dict[str, Any]) -> list[dict]:
    """Flat dict → OTel KeyValue array.

    Type dispatch per `_attr_value` (GF-742): int/bool/float/string. The backend
    currently ignores `doubleValue` (L2 acceptable gap — L3 will add aggregation
    over numeric attrs).
    """
    return [{"key": k, "value": _attr_value(v)} for k, v in attrs.items()]


def _span_to_otlp(span: Span) -> dict:
    """Single Python Span → OTLP span dict.

    Merges `status`/`error` into attributes (Span.to_dict does the same —
    the backend silently ignores the OTLP `status` field, so we must go through
    attributes). `parentSpanId` is omitted for root spans.
    """
    merged_attrs: dict[str, Any] = {**span.attributes, "status": span.status}
    if span.error:
        merged_attrs["error"] = span.error

    started_iso = _iso_z(span.started_at)
    ended_iso = _iso_z(span.ended_at)

    result: dict[str, Any] = {
        "traceId": span.trace_id,
        "spanId": span.span_id,
        "name": span.name,
        "startTimeUnixNano": str(_iso_to_ns(started_iso)) if started_iso else "",
        "endTimeUnixNano": str(_iso_to_ns(ended_iso)) if ended_iso else "",
        "attributes": _attrs_to_otlp(merged_attrs),
    }
    if span.parent_span_id is not None:
        result["parentSpanId"] = span.parent_span_id
    return result


def _build_otlp_payload(
    spans: list[Span], run_id: str, eval_id: str | None = None
) -> dict:
    """OTLP `resourceSpans` envelope.

    `eval_id` resolution (GF-727): explicit param > `_context._eval_id`
    ContextVar > None. If None, the `gf.eval_id` resource attribute is
    not included (the backend parses `gf.eval_id` only when present).
    """
    resolved_eval_id = eval_id or _context._eval_id.get()

    resource_attrs: list[dict] = [
        {"key": "service.instance.id", "value": {"stringValue": run_id}},
        {"key": "service.name", "value": {"stringValue": "ghostfactory-sdk-python"}},
    ]
    if resolved_eval_id:
        resource_attrs.append(
            {"key": "gf.eval_id", "value": {"stringValue": resolved_eval_id}}
        )

    return {
        "resourceSpans": [
            {
                "resource": {"attributes": resource_attrs},
                "scopeSpans": [{"spans": [_span_to_otlp(s) for s in spans]}],
            }
        ]
    }


async def send_span(span: Span, endpoint: str, api_key: str) -> bool:
    """POST a single span to /v1/traces in OTLP/HTTP JSON format.

    1 retry on failure. Returns True on HTTP 2xx, False otherwise. Never raises
    — SDK contract: silent drop, never cause an exception for the customer.

    The backend returns 200 + `{"partialSuccess": {"rejectedSpans": 0}}` (OTLP spec)
    — not 202 like the legacy endpoint. So the success test asserts 2xx, not 202.
    """
    payload = _build_otlp_payload([span], run_id=span.run_id, eval_id=None)
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }
    url = f"{endpoint.rstrip('/')}/v1/traces"

    for attempt in range(2):  # 0 = first try, 1 = retry
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                r = await client.post(url, json=payload, headers=headers)
                if 200 <= r.status_code < 300:
                    return True
                logger.debug(
                    "GF SDK: unexpected status %s (attempt %d)", r.status_code, attempt
                )
        except Exception as e:  # noqa: BLE001 — silent drop is the contract
            logger.debug("GF SDK: send failed (attempt %d): %s", attempt, e)

    return False
