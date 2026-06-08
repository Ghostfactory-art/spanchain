"""Per-async-task context.

A ContextVar is isolated per asyncio task — it shares state correctly across await boundaries.
Global mutable state outside a ContextVar would break under concurrent coroutines.
"""

from contextvars import ContextVar

_run_id: ContextVar[str | None] = ContextVar("gf_run_id", default=None)
_current_span_id: ContextVar[str | None] = ContextVar("gf_span_id", default=None)
# W3C trace_id (GF-884): generated on the root span, inherited by children so a whole
# run shares one trace_id. Same per-async-task isolation as the others.
_current_trace_id: ContextVar[str | None] = ContextVar("gf_trace_id", default=None)
_eval_id: ContextVar[str | None] = ContextVar("gf_eval_id", default=None)
