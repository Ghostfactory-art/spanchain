"""GhostFactory Observability — Python SDK (L1).

Public API:
    gf.init(endpoint, api_key, run_id=None)
    gf.trace(name="...")              — decorator for async functions (root span)
    async with gf.span(name, **attrs) — context manager for nested spans
    await gf.flush()                  — re-send spans buffered after failed sends (GF-943)
    gf.set_eval_id(eval_id)           — sticky eval_id for the current async context (GF-727)
    async with gf.eval_scope(eval_id) — scoped eval_id with auto-restore (GF-727)
    gf.attrs                           — OTel GenAI span attribute constants (GF-735)
"""

import functools
import logging
import secrets
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Any

from . import attrs
from ._buffer import drain as buffer_drain
from ._buffer import push as buffer_push
from ._buffer import size as buffer_size
from ._context import _current_span_id, _current_trace_id, _eval_id, _run_id
from ._exporter import send_span
from ._span import Span

__all__ = ["init", "trace", "span", "flush", "set_eval_id", "eval_scope", "attrs"]

logger = logging.getLogger("ghostfactory")

_endpoint: str | None = None
_api_key: str | None = None


def init(endpoint: str, api_key: str, run_id: str | None = None) -> str:
    """Initialize the SDK. Returns the effective run_id (generated if not provided)."""
    global _endpoint, _api_key
    _endpoint = endpoint
    _api_key = api_key
    rid = run_id or str(uuid.uuid4())
    _run_id.set(rid)
    return rid


def set_eval_id(eval_id: str | None) -> None:
    """Set eval_id for the current async context (and its child tasks)."""
    _eval_id.set(eval_id)


@asynccontextmanager
async def eval_scope(eval_id: str):
    """Scope eval_id to the current async task + its children.

    Restores the previous value on exit (even on exception) — safe for
    asyncio.gather and TaskGroup. The ContextVar ensures per-task isolation.
    """
    token = _eval_id.set(eval_id)
    try:
        yield
    finally:
        _eval_id.reset(token)


def trace(name: str, **kwargs: Any):
    """Decorator for async functions — creates a root span for the given function."""

    def decorator(fn):
        @functools.wraps(fn)
        async def wrapper(*args, **kw):
            async with span(name, **kwargs):
                return await fn(*args, **kw)

        return wrapper

    return decorator


@asynccontextmanager
async def span(name: str, **attributes: Any):
    """Async context manager. The parent is read from the ContextVar automatically.

    On exception: status="error", error=str(e), then the exception propagates out.
    A send failure → falls into the buffer (silent), does not raise.
    """
    if _endpoint is None or _api_key is None:
        raise RuntimeError("ghostfactory.init() must be called first")

    parent_id = _current_span_id.get()
    run_id = _run_id.get()
    if run_id is None:
        raise RuntimeError("ghostfactory.init() did not set run_id")

    # W3C trace_id (GF-884): the root span (no parent in context) mints a 128-bit id;
    # child spans inherit it from the ContextVar so a whole run shares one trace_id.
    trace_id = _current_trace_id.get() or secrets.token_hex(16)

    s = Span(
        span_id=secrets.token_hex(8),
        name=name,
        run_id=run_id,
        parent_span_id=parent_id,
        started_at=datetime.now(timezone.utc),
        trace_id=trace_id,
        attributes=dict(attributes),
    )

    trace_token = _current_trace_id.set(trace_id)
    span_token = _current_span_id.set(s.span_id)
    try:
        yield s
    except Exception as e:
        s.status = "error"
        s.error = str(e)
        raise
    finally:
        s.ended_at = datetime.now(timezone.utc)
        _current_span_id.reset(span_token)
        _current_trace_id.reset(trace_token)
        try:
            sent = await send_span(s, _endpoint, _api_key)
        except Exception:  # noqa: BLE001 — SDK never raises to caller
            sent = False
        if not sent:
            buffer_push(s)
            logger.warning(
                "GF SDK: span %r failed to send — buffered for gf.flush() (%d buffered)",
                s.name,
                buffer_size(),
            )


async def flush() -> int:
    """Re-send spans buffered after failed sends (GF-943). Returns the sent count.

    Drains the buffer and re-sends each span individually; spans that still
    fail go back into the buffer (order preserved among themselves). Send
    failures never raise (SDK contract) — only calling before `init()` does.
    """
    if _endpoint is None or _api_key is None:
        raise RuntimeError("ghostfactory.init() must be called first")

    spans = buffer_drain()
    sent_count = 0
    for s in spans:
        try:
            ok = await send_span(s, _endpoint, _api_key)
        except Exception:  # noqa: BLE001 — SDK never raises to caller
            ok = False
        if ok:
            sent_count += 1
        else:
            buffer_push(s)

    failed = len(spans) - sent_count
    if failed:
        logger.warning(
            "GF SDK: flush() could not deliver %d span(s) — re-buffered for the next flush",
            failed,
        )
    return sent_count
