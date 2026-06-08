"""Tests for the set_eval_id / eval_scope ContextVar API (GF-727 Python parity)."""

import asyncio

import ghostfactory as gf
from ghostfactory import _context
from ghostfactory._exporter import _build_otlp_payload


def test_set_eval_id_sets_contextvar():
    gf.set_eval_id("eval-1")
    assert _context._eval_id.get() == "eval-1"


def test_set_eval_id_none_clears():
    gf.set_eval_id("eval-x")
    gf.set_eval_id(None)
    assert _context._eval_id.get() is None


async def test_eval_scope_sets_inside():
    async with gf.eval_scope("eval-scope-1"):
        assert _context._eval_id.get() == "eval-scope-1"


async def test_eval_scope_restores_after_exit():
    gf.set_eval_id("outer")
    async with gf.eval_scope("inner"):
        assert _context._eval_id.get() == "inner"
    assert _context._eval_id.get() == "outer"


async def test_eval_scope_restores_after_exception():
    gf.set_eval_id("outer")
    try:
        async with gf.eval_scope("inner"):
            raise RuntimeError("boom")
    except RuntimeError:
        pass
    assert _context._eval_id.get() == "outer"


async def test_eval_scope_isolation_gather():
    """asyncio.gather: two concurrent scopes must not contaminate each other."""
    results: dict[str, str | None] = {}

    async def task_a():
        async with gf.eval_scope("eval-A"):
            await asyncio.sleep(0.01)
            results["a"] = _context._eval_id.get()

    async def task_b():
        async with gf.eval_scope("eval-B"):
            await asyncio.sleep(0.01)
            results["b"] = _context._eval_id.get()

    await asyncio.gather(task_a(), task_b())
    assert results["a"] == "eval-A"
    assert results["b"] == "eval-B"


def test_otlp_payload_picks_up_contextvar():
    """_build_otlp_payload without an explicit eval_id arg → falls back to the ContextVar."""
    gf.set_eval_id("payload-eval-1")

    payload = _build_otlp_payload(spans=[], run_id="r1")
    attrs = payload["resourceSpans"][0]["resource"]["attributes"]
    eval_attr = next(a for a in attrs if a["key"] == "gf.eval_id")
    assert eval_attr["value"]["stringValue"] == "payload-eval-1"


def test_otlp_payload_explicit_arg_wins_over_contextvar():
    """An explicit eval_id takes precedence over the ContextVar (least-surprise)."""
    gf.set_eval_id("from-contextvar")

    payload = _build_otlp_payload(spans=[], run_id="r1", eval_id="from-arg")
    attrs = payload["resourceSpans"][0]["resource"]["attributes"]
    eval_attr = next(a for a in attrs if a["key"] == "gf.eval_id")
    assert eval_attr["value"]["stringValue"] == "from-arg"
