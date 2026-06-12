"""In-memory buffer for spans that failed to send. Max 1000 items (FIFO drop).

GF-943: FIFO eviction is permanent data loss — it is logged as a warning so an
outage is never fully silent. Buffered spans are re-sent via `gf.flush()`.
"""

import logging
from collections import deque

from ._span import Span

logger = logging.getLogger("ghostfactory")

_buffer: "deque[Span]" = deque(maxlen=1000)


def push(span: Span) -> None:
    if _buffer.maxlen is not None and len(_buffer) == _buffer.maxlen:
        dropped = _buffer[0]
        logger.warning(
            "GF SDK: buffer full (%d) — dropping oldest span %r (permanent data loss)",
            _buffer.maxlen,
            dropped.name,
        )
    _buffer.append(span)


def drain() -> list[Span]:
    spans = list(_buffer)
    _buffer.clear()
    return spans


def size() -> int:
    return len(_buffer)
