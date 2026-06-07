Datum: 2026-05-16
Status: Draft — čeká na Gemini review
Autor: Jiří Joneš

Kontext

GhostFactory Observability backend běží v Elixiru. Zákazníkovi agenti jsou v Pythonu (primárně) nebo TypeScriptu. Potřebujeme definovat jak SDK komunikuje s backendem — přesný protokol, směr dat, autentizaci, error handling a context propagation.

ADR-002-A: Komunikační protokol

Rozhodnutí:

L1: HTTP POST JSON na /ingest (vlastní formát)

L2: OTLP/HTTP Protobuf na /v1/traces (OTel standard)

Směr dat je jednosměrný: SDK → backend.
SDK nikdy nepřijímá data během normálního provozu. Backend je push-only endpoint.

Výjimka — Audit Replay (L1):
SDK může volat GET /api/runs/:run_id pro stažení Ledgeru. Toto je read-only, separátní endpoint od ingestion.

Důvod:

HTTP JSON = nulové závislosti v Python SDK

OTLP L2 = kompatibilita s LangChain, CrewAI, OpenTelemetry SDK

Jednosměrný push = SDK zůstává hloupý, žádná state synchronizace

ADR-002-B: SDK architektura — "Dumb Exporter" pattern

Rozhodnutí: SDK je maximálně hloupý exporter. Žádná business logika, žádné rozhodování.

Co SDK dělá:

Generuje span_id (UUID nebo random hex)

Zaznamená started_at / ended_at

Sestaví JSON payload

HTTP POST na /ingest

Bufferuje lokálně pokud backend není dostupný (max N spanů, pak drop)

Co SDK NEDĚLÁ:

Nezná epochy, batch strategii, ani hash-chain

Neřeší ordering (to je backend)

Neví o dead-letter queue

Nepočítá retry (max 1 retry, pak drop — backend má DLQ)

Důvod:

Cokoliv v Pythonu SDK musíme zrcadlit v TypeScript SDK

Logika v backendu = jeden fix opraví všechny klienty

ADR-002-C: Context propagation v async Pythonu

Problém:

async def agent_run(task):
    span_id = harness.start_span("agent_run")  # ← jak předat span_id do nested callů?
    result = await llm.complete(task)           # ← tady chceme child span
    harness.end_span(span_id)

Rozhodnutí: Python contextvars.ContextVar pro implicitní propagaci run_id a current_span_id.

_run_id: ContextVar[str] = ContextVar('gf_run_id', default=None)
_span_id: ContextVar[str] = ContextVar('gf_span_id', default=None)

@gf.trace(name="agent_run")
async def agent_run(task):
    # run_id a parent_span_id jsou automaticky dostupné přes ContextVar
    async with gf.span("llm_call"):  # parent_span_id se nastaví automaticky
        result = await llm.complete(task)
    return result

Výhoda: Funguje přes asyncio.create_task, asyncio.gather a concurrent.futures. Vývojář nepředává kontext explicitně.

Limit: Nefunguje přes multiprocessing — dokumentovat.

ADR-002-D: LLM call tracing a Decision Trail

Rozhodnutí: SDK zachytí LLM call a pošle jako event_type: "llm_call" span s decision trail fields v payload.

Payload schema:

{
  "span_id": "abc123",
  "name": "llm_call",
  "event_type": "llm_call",
  "started_at": "2026-05-16T06:00:00Z",
  "ended_at": "2026-05-16T06:00:01Z",
  "attributes": {
    "model": "claude-sonnet-4-20250514",
    "prompt_tokens": 892,
    "completion_tokens": 156,
    "cost_usd": 0.0023,
    "input": "Analyze this document...",
    "thinking": "The document appears to be...",
    "decision": "I will extract key entities first",
    "output": "Key entities found: ..."
  }
}

thinking field:

Claude API: zachytit z extended_thinking response block

OpenAI: null (reasoning modely nemají veřejné CoT)

Ostatní: null nebo z custom system prompt instrukce

Implementace:

async def trace_llm_call(client, messages, **kwargs):
    async with gf.span("llm_call") as span:
        response = await client.messages.create(
            messages=messages,
            thinking={"type": "enabled", "budget_tokens": 5000},
            **kwargs
        )
        span.set_attributes({
            "model": kwargs.get("model"),
            "input": messages[-1]["content"][:500],  # truncate
            "thinking": _extract_thinking(response),
            "output": response.content[-1].text[:500]
        })
        return response

ADR-002-E: Autentizace

L1: API key v HTTP headeru:

X-GF-API-Key: gf_live_abc123

L2: JWT per projekt (multi-tenant)

SDK konfigurace:

gf.init(
    endpoint="http://localhost:4000",
    api_key=os.environ["GF_API_KEY"]
)

ADR-002-F: SDK error handling

Rozhodnutí: SDK nikdy nevyhazuje výjimku zákazníkovi kvůli observability problému.

# SDK failure je silent — agent pokračuje
try:
    _send_span(span_data)
except Exception as e:
    logger.debug(f"GF SDK: failed to send span: {e}")
    # drop — backend má DLQ pro Elixir-side failures

Local buffer: Pokud backend není dostupný, SDK bufferuje max 1000 spanů v paměti. Po překročení limitu → drop oldest. Buffer se flushne při dalším úspěšném spojení.

Open otázky pro Gemini review

ContextVar vs explicitní předávání — je ContextVar správný pattern pro Python async, nebo existuje lepší přístup?

Batch vs per-span HTTP — SDK posílá každý span zvlášť nebo batches? Jaký je trade-off?

thinking field truncation — 500 chars je dost nebo moc? Jak ostatní SDK to řeší?

SDK buffer persistence — pokud agent crashne, buffer je ztracen. Má smysl file-based buffer pro L1?

multiprocessing — ContextVar nefunguje přes procesy. Jak to řešit pro agenty v process pool?