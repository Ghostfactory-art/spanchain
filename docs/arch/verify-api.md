# Verify API — `POST /api/verify` (artifact chain proof, GF-972)

Endpoint pro důkaz, že **artefakt** (manifest.json, result.json, verdict.json, …) existoval
v daném čase nezměněný. Vstupem je SHA-256 hash obsahu artefaktu; backend najde ledger entry,
v jejímž `payload` ten hash leží, a ověří hash-chain od genesis až po danou entry.

Žije v `:api` pipeline na portu 4001 (za `Corsica` → `AuthPlug` → `RateLimiter`). Nesahá na
ingest pipeline (port 4000) ani na existující `GET /api/runs/:run_id/verify` (`verify_run`,
ověřuje celý run podle `run_id`).

## 1. Request / Response

**Request**

```
POST /api/verify
Authorization: Bearer <GF_API_KEY>
Content-Type: application/json

{"sha256": "<64hex>"}
```

**Response — nalezeno** (`200`)

```json
{
  "found": true,
  "verified": true,
  "run_id": "run-abc",
  "span_id": "a1",
  "trace_id": "…|null",
  "timestamp": "2026-06-14T22:00:00.000000Z",
  "chain_position": 1,
  "proof": {
    "guarantees": "SHA-256 hash existed at timestamp T in an unbroken chain from genesis to this span.",
    "does_not_guarantee": "Semantic correctness of the artifact content."
  }
}
```

- `verified` — `true` ⇔ každá entry od genesis (`epoch_id: 0, seq: 0`) až po nalezenou entry
  se přepočítá na sedící `hash` a navazuje `prev_hash` (napříč epochami; sdílený `walk_chain/1`
  s `verify_ledger/1`). Při jakékoli manipulaci `payload`/`prev_hash` v prefixu → `false`.
- `chain_position` — 0-based index nalezené entry od genesis (počet entries v prefixu − 1).
  V tabulce `ledger_entries` neexistuje sloupec „position" — pozice je dvojice `(epoch_id, seq)`,
  index se odvozuje.
- `timestamp` — `inserted_at` nalezené entry (`utc_datetime_usec`, ISO-8601).

**Response — nenalezeno** (`200`)

```json
{"found": false}
```

**Response — chybějící parametr** (`400`)

```json
{"error": "missing_required_params", "hint": "body must contain {\"sha256\": \"...\"}"}
```

Lookup je generický: hledá se entry, kde **libovolná** hodnota v `payload` JSONB rovná se
zadanému `sha256` (`jsonb_each_text`), nezávisle na názvu klíče (`gf.manifest.sha256`,
`gf.result.sha256`, … nejsou napevno). Bez GIN indexu = potenciální seq scan; pro interní
Foreman + compliance demo (nízký traffic) akceptovatelné, GIN index je samostatný L3 issue.

## 2. Co proof garantuje (`guarantees`)

SHA-256 hash artefaktu **existoval v čase T** zapsaný v ledgeru **v neporušeném hash-řetězu
od genesis** až po danou entry. Tj. obsah artefaktu byl v daný okamžik takový, jaký tvrdíte,
a od té doby s řetězem nikdo nemanipuloval (jinak `verified: false`).

## 3. Co proof negarantuje (`does_not_guarantee`)

**Sémantickou správnost** obsahu artefaktu. Ledger dokazuje *integritu a existenci v čase*,
ne že rozhodnutí/výsledek byl *věcně správný*. „Agent vydal toto rozhodnutí v tomto čase" —
ne „toto rozhodnutí bylo dobré".

## 4. Foreman integrace (wiring gap #4)

Foreman po doběhnutí jobu spočítá SHA-256 každého artefaktu (manifest/result/verdict) a zavolá:

```bash
curl -s -X POST https://<host>/api/verify \
  -H "Authorization: Bearer $GF_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"sha256":"'"$(sha256sum verdict.json | cut -d' ' -f1)"'"}' | jq .
# → {"found":true,"verified":true,"chain_position":N,"proof":{…}}
```

`found:false` → artefakt nebyl nikdy ingestován (chybí span s jeho hashem). `verified:false` →
artefakt v ledgeru je, ale řetěz k němu byl porušen (tamper signál pro compliance). Synchronní
chain-walk od genesis je O(n) v pozici spanu — pro interní/low-throughput volání OK; background
async verifikace je budoucí L3 issue.
