"""GhostFactory Observability — Python SDK (L1).

Public API:
    gf.init(endpoint, api_key, run_id=None)
    gf.trace(name="...")              — decorator for async functions (root span)
    async with gf.span(name, **attrs) — context manager for nested spans
    await gf.flush()                  — drain queued + buffered spans (GF-943/GF-944)
    gf.set_eval_id(eval_id)           — sticky eval_id for the current async context (GF-727)
    async with gf.eval_scope(eval_id) — scoped eval_id with auto-restore (GF-727)
    gf.attrs                           — OTel GenAI span attribute constants (GF-735)
"""

import asyncio
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
from ._exporter import close_client, send_batch, send_span
from ._span import Span

__all__ = ["init", "trace", "span", "flush", "set_eval_id", "eval_scope", "attrs"]

logger = logging.getLogger("ghostfactory")

_endpoint: str | None = None
_api_key: str | None = None

# GF-944: batch queue state — lazy-created in _ensure_queue() (first async call).
# NEVER created in init() (sync) — event loop may not exist yet.
_pending_queue: "asyncio.Queue | None" = None
_flush_task: "asyncio.Task | None" = None

BATCH_SIZE = 50
BATCH_TIMEOUT_S = 5.0


async def _ensure_queue() -> asyncio.Queue:
    global _pending_queue, _flush_task
    if _pending_queue is None:
        _pending_queue = asyncio.Queue()
        _flush_task = asyncio.create_task(_flush_loop())
    return _pending_queue


async def _flush_loop() -> None:
    """Background drain loop — sends batches of up to BATCH_SIZE every BATCH_TIMEOUT_S."""
    while True:
        batch = []
        try:
            deadline = asyncio.get_running_loop().time() + BATCH_TIMEOUT_S
            while len(batch) < BATCH_SIZE:
                remaining = deadline - asyncio.get_running_loop().time()
                if remaining <= 0:
                    break
                try:
                    item = await asyncio.wait_for(
                        _pending_queue.get(), timeout=max(remaining, 0.001)
                    )
                    batch.append(item)
                except asyncio.TimeoutError:
                    break
        except asyncio.CancelledError:
            raise
        except Exception:
            pass

        if batch:
            ok = await send_batch(batch, _endpoint, _api_key)
            if not ok:
                for item in batch:
                    buffer_push(item["span"])
                logger.warning(
                    "GF SDK: batch send failed — %d span(s) buffered",
                    len(batch),
                )


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
    """Async context manager. Enqueues spans for batched delivery (GF-944).

    On exception: status="error", error=str(e), then the exception propagates out.
    A send failure → falls into the buffer (silent). Never raises to the caller.
    Call gf.flush() to drain the queue immediately (e.g. before process exit).
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
        eval_id = _eval_id.get()
        run_id_val = _run_id.get()
        queue = await _ensure_queue()
        await queue.put({"span": s, "run_id": run_id_val, "eval_id": eval_id})


async def flush() -> int:
    """Drain queued + buffered spans immediately. Returns the sent count.

    1. Cancels the background flush loop.
    2. Re-sends any previously buffered (failed) spans individually.
    3. Sends all pending queue items as a batch.
    4. Closes the HTTP client (recreated lazily on the next span).

    Never raises on send failure (SDK contract). Only raises if called before init().
    """
    if _endpoint is None or _api_key is None:
        raise RuntimeError("ghostfactory.init() must be called first")

    global _pending_queue, _flush_task

    # 1. Cancel background flush loop
    if _flush_task is not None:
        _flush_task.cancel()
        try:
            await _flush_task
        except asyncio.CancelledError:
            pass
        _flush_task = None

    # 2. Drain OLD failure buffer first — so queue failures below don't
    #    get double-processed if they also end up in the buffer.
    old_failed = buffer_drain()

    # 3. Drain pending queue
    queue_items = []
    if _pending_queue is not None:
        while not _pending_queue.empty():
            queue_items.append(_pending_queue.get_nowait())
        _pending_queue = None

    sent_count = 0

    # 4. Resend old buffer items individually (preserves retry semantics)
    buffer_failed = 0
    for s in old_failed:
        try:
            ok = await send_span(s, _endpoint, _api_key)
        except Exception:  # noqa: BLE001
            ok = False
        if ok:
            sent_count += 1
        else:
            buffer_failed += 1
            buffer_push(s)

    if buffer_failed:
        logger.warning(
            "GF SDK: flush() could not deliver %d span(s) — re-buffered for next flush",
            buffer_failed,
        )

    # 5. Send queue items as a batch (one HTTP call per run_id/eval_id group)
    if queue_items:
        ok = await send_batch(queue_items, _endpoint, _api_key)
        if ok:
            sent_count += len(queue_items)
        else:
            for item in queue_items:
                buffer_push(item["span"])
            logger.warning(
                "GF SDK: flush() could not deliver %d span(s) — buffered for next flush",
                len(queue_items),
            )

    # 6. Close the HTTP client (recreated lazily on the next span)
    await close_client()

    return sent_count
