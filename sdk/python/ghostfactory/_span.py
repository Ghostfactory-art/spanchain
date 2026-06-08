import secrets
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any


def _iso_z(dt: datetime | None) -> str | None:
    """ISO 8601 with a 'Z' suffix instead of '+00:00' — the backend (Elixir DateTime.from_iso8601) expects it."""
    if dt is None:
        return None
    return dt.isoformat().replace("+00:00", "Z")


@dataclass
class Span:
    span_id: str
    name: str
    run_id: str
    parent_span_id: str | None
    started_at: datetime
    # W3C 128-bit trace_id (GF-884). default_factory so directly-constructed spans
    # always carry a valid id; gf.span() passes the context-resolved one (root generates,
    # child inherits) so a whole run shares one trace_id.
    trace_id: str = field(default_factory=lambda: secrets.token_hex(16))
    ended_at: datetime | None = None
    attributes: dict[str, Any] = field(default_factory=dict)
    status: str = "ok"
    error: str | None = None

    def set(self, key: str, value: Any) -> None:
        """Set an attribute after the span is created (e.g. after an LLM call finishes)."""
        self.attributes[key] = value

    def to_dict(self) -> dict:
        return {
            "span_id": self.span_id,
            "trace_id": self.trace_id,
            "name": self.name,
            "started_at": _iso_z(self.started_at),
            "ended_at": _iso_z(self.ended_at),
            "parent_span_id": self.parent_span_id,
            "attributes": {
                **self.attributes,
                "status": self.status,
                **({"error": self.error} if self.error else {}),
            },
        }
