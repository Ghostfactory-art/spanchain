"""In-memory buffer for spans that failed to send. Max 1000 items (FIFO drop)."""

from collections import deque

from ._span import Span

_buffer: "deque[Span]" = deque(maxlen=1000)


def push(span: Span) -> None:
    _buffer.append(span)


def drain() -> list[Span]:
    spans = list(_buffer)
    _buffer.clear()
    return spans


def size() -> int:
    return len(_buffer)
