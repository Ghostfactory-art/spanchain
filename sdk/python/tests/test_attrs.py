"""Tests for the gen_ai.* attribute constants (GF-735)."""

import ghostfactory as gf
from ghostfactory import attrs
from ghostfactory._exporter import _attr_value


def test_attrs_namespace_exported_on_package():
    # gf.attrs must be importable (re-export from __init__.py)
    assert gf.attrs is attrs


def test_token_constants_match_otel_genai_spec():
    # OTel GenAI Semantic Conventions stable keys
    assert attrs.GEN_AI_USAGE_INPUT_TOKENS == "gen_ai.usage.input_tokens"
    assert attrs.GEN_AI_USAGE_OUTPUT_TOKENS == "gen_ai.usage.output_tokens"
    assert attrs.GEN_AI_USAGE_TOTAL_TOKENS == "gen_ai.usage.total_tokens"


def test_provider_model_constants():
    assert attrs.GEN_AI_SYSTEM == "gen_ai.system"
    assert attrs.GEN_AI_REQUEST_MODEL == "gen_ai.request.model"


def test_cost_uses_gf_namespace():
    # `gf.*` not `gen_ai.*` — GF extension outside the OTel spec
    assert attrs.GF_USAGE_COST_USD == "gf.usage.cost_usd"
    assert attrs.GF_USAGE_COST_USD.startswith("gf.")


def test_token_int_dispatches_to_intValue():
    # Key integration GF-742 + GF-735: int tokens → intValue over the OTLP wire
    assert _attr_value(128) == {"intValue": 128}
    assert _attr_value(0) == {"intValue": 0}


def test_cost_float_dispatches_to_doubleValue():
    # GF_USAGE_COST_USD is a float → doubleValue (the backend ignores it for now, L3 follow-up)
    assert _attr_value(0.00096) == {"doubleValue": 0.00096}


# --------------------------------------------------------------------------
# GF-738 — agent config versioning
# --------------------------------------------------------------------------


def test_agent_constants_use_gf_namespace():
    assert attrs.GF_AGENT_MODEL == "gf.agent.model"
    assert attrs.GF_AGENT_SYSTEM_PROMPT_HASH == "gf.agent.system_prompt_hash"
    assert attrs.GF_AGENT_TEMPERATURE == "gf.agent.temperature"
    assert attrs.GF_AGENT_VERSION == "gf.agent.version"
    for k in (
        attrs.GF_AGENT_MODEL,
        attrs.GF_AGENT_SYSTEM_PROMPT_HASH,
        attrs.GF_AGENT_TEMPERATURE,
        attrs.GF_AGENT_VERSION,
    ):
        assert k.startswith("gf.agent.")


def test_hash_prompt_returns_16_hex_chars():
    result = attrs.hash_prompt("Hello, world!")
    assert len(result) == 16
    assert all(c in "0123456789abcdef" for c in result)


def test_hash_prompt_is_idempotent():
    prompt = "You are a helpful assistant."
    assert attrs.hash_prompt(prompt) == attrs.hash_prompt(prompt)


def test_hash_prompt_differs_for_different_inputs():
    assert attrs.hash_prompt("Prompt A") != attrs.hash_prompt("Prompt B")


def test_hash_prompt_empty_string_valid():
    # SHA-256("") is a deterministic valid hash — no crash
    result = attrs.hash_prompt("")
    assert len(result) == 16
    # SHA-256 of empty string starts with "e3b0c44298fc1c14..."
    assert result == "e3b0c44298fc1c14"


# --------------------------------------------------------------------------
# GF-736 — reasoning capture
# --------------------------------------------------------------------------


def test_reasoning_constants_use_gf_namespace():
    assert attrs.GF_REASONING_THOUGHT == "gf.reasoning.thought"
    assert attrs.GF_REASONING_CONSIDERED == "gf.reasoning.considered"
    assert attrs.GF_REASONING_REJECTED == "gf.reasoning.rejected"
    for k in (
        attrs.GF_REASONING_THOUGHT,
        attrs.GF_REASONING_CONSIDERED,
        attrs.GF_REASONING_REJECTED,
    ):
        assert k.startswith("gf.reasoning.")


def test_reasoning_cross_language_parity():
    # Pinned by string-value lock — if TS changes a value, vitest on CI fails
    # at the same time (TS attrs.test.ts has identical literal assertions).
    assert attrs.GF_REASONING_THOUGHT == "gf.reasoning.thought"
    assert attrs.GF_REASONING_CONSIDERED == "gf.reasoning.considered"
    assert attrs.GF_REASONING_REJECTED == "gf.reasoning.rejected"


# --------------------------------------------------------------------------
# GF-737 — task delegation metadata
# --------------------------------------------------------------------------


def test_task_constants_use_gf_namespace():
    assert attrs.GF_TASK_REASON == "gf.task.reason"
    assert attrs.GF_TASK_INPUT == "gf.task.input"
    assert attrs.GF_TASK_DELEGATED_BY == "gf.task.delegated_by"
    for k in (attrs.GF_TASK_REASON, attrs.GF_TASK_INPUT, attrs.GF_TASK_DELEGATED_BY):
        assert k.startswith("gf.task.")


def test_task_cross_language_parity():
    # Pinned by string-value lock — TS attrs.test.ts has identical literal assertions.
    assert attrs.GF_TASK_REASON == "gf.task.reason"
    assert attrs.GF_TASK_INPUT == "gf.task.input"
    assert attrs.GF_TASK_DELEGATED_BY == "gf.task.delegated_by"
