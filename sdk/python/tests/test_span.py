from datetime import datetime, timezone

from ghostfactory._span import Span


def test_to_dict_includes_status_ok_by_default():
    s = Span(
        span_id="abc",
        name="x",
        run_id="r",
        parent_span_id=None,
        started_at=datetime(2026, 5, 17, 10, 0, 0, tzinfo=timezone.utc),
        ended_at=datetime(2026, 5, 17, 10, 0, 1, tzinfo=timezone.utc),
    )
    d = s.to_dict()

    assert d["span_id"] == "abc"
    assert d["name"] == "x"
    assert d["parent_span_id"] is None
    assert d["started_at"] == "2026-05-17T10:00:00Z"
    assert d["ended_at"] == "2026-05-17T10:00:01Z"
    assert d["attributes"]["status"] == "ok"
    assert "error" not in d["attributes"]


def test_to_dict_includes_error_when_status_error():
    s = Span(
        span_id="abc",
        name="x",
        run_id="r",
        parent_span_id=None,
        started_at=datetime(2026, 5, 17, 10, 0, 0, tzinfo=timezone.utc),
        status="error",
        error="boom",
    )
    d = s.to_dict()

    assert d["attributes"]["status"] == "error"
    assert d["attributes"]["error"] == "boom"


def test_iso_z_suffix_replaces_plus_zero():
    """The backend DateTime.from_iso8601 accepts both, but Z is the canonical form."""
    s = Span(
        span_id="a",
        name="n",
        run_id="r",
        parent_span_id=None,
        started_at=datetime(2026, 5, 17, 10, 0, 0, tzinfo=timezone.utc),
    )
    assert s.to_dict()["started_at"].endswith("Z")


def test_set_mutates_attributes():
    s = Span(
        span_id="a",
        name="n",
        run_id="r",
        parent_span_id=None,
        started_at=datetime.now(timezone.utc),
    )
    s.set("model", "claude-sonnet-4-6")
    s.set("tokens", 128)

    d = s.to_dict()
    assert d["attributes"]["model"] == "claude-sonnet-4-6"
    assert d["attributes"]["tokens"] == 128
