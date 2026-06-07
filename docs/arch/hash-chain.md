<!-- Source: architecture-map.md §5 — Hash-chain invariant -->

## 5. Hash-chain invariant — jak funguje a proč

### Co je hash-chain

Každý záznam v `ledger_entries` má sloupce:

- `seq` — pořadové číslo uvnitř epochy (0..999)
- `epoch_id` — pořadové číslo epochy (0, 1, 2, ...)
- `prev_hash` — hash předchozího záznamu (NULL pro úplně první)
- `hash` — SHA256 hex tohoto záznamu
- `event_type` — string discriminator („llm_call", „tool_call", ...)
- `parent_span_id` — pro stromovou hierarchii spans
- `payload` — opaque JSON mapa s celým spanem
- + projection columns `span_id`, `trace_id`, `started_at`, `ended_at`, `status` (GF-669/GF-653/GF-790, **NEJSOU** v hashi)

### Co vstupuje do hashe

Z `compute_hash/7` v `ledger.ex` (post GF-787):

```elixir
data =
  "#{Integer.to_string(seq)}:#{prev_hash || "nil"}:#{event_type}:" <>
    "#{canonical_encode(payload)}:#{parent_span_id || "nil"}:#{run_id}:#{Integer.to_string(epoch_id)}"
:crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
```

Pořadí: `seq`, `prev_hash`, `event_type`, `canonical_encode(payload)`,
`parent_span_id`, `run_id`, `epoch_id`. **Sedm polí**, separator `:`. `nil` se hashuje
jako literál `"nil"` — záměrně, aby NULL byl deterministický. Integer pole (`seq`,
`epoch_id`) jdou do stringu přes explicitní `Integer.to_string/1` (GF-812 — v
kryptografickém kódu musí být každá konverze záměrná, ne delegovaná na `String.Chars`
protocol dispatch; výstup je bit-for-bit identický, pinned regression test v `ledger_test.exs`).

**`run_id` + `epoch_id` JSOU v hashi (GF-787)** — entry je tak kryptograficky vázána
ke svému runu/epoše, ne jen SQL filtrem ve `verify_ledger` (`where run_id == ^x`). Dřív
(5 polí, pre-GF-787) šlo entry potichu přesunout pod jiný `run_id`/`epoch_id` v DB bez
detekce; teď to rozbije chain. **Rozsah (poctivě):** zavírá naivní SQL relabel/přesun;
hash zůstává *unkeyed* → útočník s DB write + recompute pořád zfalšuje čistý řetěz a
truncation ocasu je neviditelná (keyed/HMAC + externí anchoring = budoucí práce).

### Proč `canonical_encode`

`payload_serializer.ex:14-24`: Elixir mapy s >32 klíči přechází na HAMT
reprezentaci, která NEGARANTUJE pořadí klíčů při iteraci. `Jason.encode!(map)`
proto může pro identická data vrátit různé JSON stringy podle insertion
order. To by způsobilo false `{:error, :chain_broken}` u runů s velkými
payloady. `canonical_encode` rekurzivně serializuje s lex-sortem klíčů
přímo nad seznamem 2-tuplů — pořadí klíčů deterministicky stabilní.
GF-654 zavedeno právě kvůli tomuto. Past, kterou prompt zmiňuje: `Map.new`
po sortu pořadí klíčů okamžitě ZTRATÍ (mapa znovu hashuje klíče) — proto
build JSON stringu ručně.

### `verify_ledger/1` — co dělá

Z `ledger.ex:181-205`:

```elixir
entries = (from l in Ledger, where l.run_id == ^run_id, order_by [asc: :epoch_id, asc: :seq])
Enum.reduce_while(entries, {:ok, 0, nil}, fn e, {:ok, count, last_hash} ->
  expected = compute_hash(e.seq, e.prev_hash, e.event_type, e.payload, e.parent_span_id, e.run_id, e.epoch_id)
  cond do
    e.prev_hash != last_hash  -> {:halt, {:error, :chain_broken}}     # gap detection
    expected != e.hash         -> {:halt, {:error, :chain_broken}}     # tamper detection
    true                       -> {:cont, {:ok, count + 1, e.hash}}    # advance
  end
end)
```

Funkce recomputuje hash každého řádku a porovnává:
1. **Tamper**: `expected != e.hash` — někdo přepsal `payload`/`event_type`/`parent_span_id` v DB ale nepřepočítal `hash`. SHA256 to odhalí.
2. **Gap**: `e.prev_hash != last_hash` — chybí řádek uprostřed (dead-letter / DELETE). Záznam `n+1` má `prev_hash = hash(n)`, ale v reduce už jsme přeskočili `n`, takže `last_hash` neodpovídá.

### Kdy `{:error, :chain_broken}` v praxi

| Situace | Důvod chain_broken |
|---|---|
| **Dead-letter** | Batch po 3 retries selhal → `DeadLetter.store/3` → row neexistuje v Ledger. Hash chain pokračuje (SGS i tak inkrementoval `seq`/`prev_hash`), ale gap detekován. Záměrný audit signál „data exists, but not in authoritative source." (`dead_letter.ex:1-15` › „není součástí hash-chainu... `verify_ledger` selže — to je záměrné") |
| **Tamper** | Manuální `Repo.update_all` na payload/parent_span_id sloupec. Smoke test ukázán v development.md:81-91. |
| **Race v Pipeline retry** | Pokud retry úspěšný ale duplicitní insert → uniq index `(run_id, epoch_id, seq)` → idempotent skip. NE chain_broken — `on_conflict: :nothing` v `ledger.ex:148-150`. |
| **Epoch Island Attack** | Někdo smaže celou epochu (např. `epoch_id = 5` všechny řádky). První řádek epochy 6 má `prev_hash = hash(last_row_of_epoch_5)`, ale `last_hash` v reduce je `hash(last_row_of_epoch_4)`. → `chain_broken`. **TOTO JE PŘESNĚ TO, CO GF-666 PŘIDAL.** |

### Epoch boundary — proč existuje a co je „Epoch Island Attack"

`session_gen_server.ex:175-186`:

```elixir
defp maybe_epoch_boundary(%{seq: seq} = state) when seq > 0 and rem(seq, @epoch_size) == 0 do
  :telemetry.execute([:gf, :epoch, :boundary], ...)
  %{state | epoch_id: state.epoch_id + 1, seq: 0, prev_hash: state.prev_hash}
end
```

Každých `@epoch_size = 1_000` spans (`session_gen_server.ex:41`) se epocha
rolluje: `epoch_id++`, `seq=0`. Důvod: index na `(run_id, epoch_id, seq)` má
omezený prostor — bez epoch by `seq` rostlo do nekonečna a operace nad chainem
(verify, range queries) by lineárně zpomalovaly s délkou runu.

**Klíčový GF-666 fix**: `prev_hash: state.prev_hash` — hash POSLEDNÍHO záznamu
předchozí epochy se ZACHOVÁ jako `prev_hash` PRVNÍHO záznamu nové epochy.
Bez toho by každá epocha začínala `prev_hash = nil` a verify_ledger by byl
imunní vůči smazání celé epochy (pre-GF-666 bug: „Epoch Island Attack" —
adversary smaže `epoch_id = N`, epocha N+1 začíná nil-prev_hash, vypadá to
jako legitimní start, integrity check pass).

Pre-GF-666: `verify_ledger` resetoval `last_hash` na epoch boundary
→ ostrov nedetekovaný. Post-GF-666: `last_hash` se přenáší napříč epochami
v reduce loop (`ledger.ex:190-199`) → `entry.prev_hash != last_hash` u
prvního záznamu epochy N+1 → `{:error, :chain_broken}`. ✅

---

