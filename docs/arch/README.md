# arch/ — detailní architektonické sekce

Tyto soubory drží **detailní prózu** rozdělenou z `../architecture-map.md`. Hlavní
`architecture-map.md` zůstává rozcestníkem: §1 přehled + stub sekce + plná §4 Dependency
Matrix. Detail každé sekce žije zde.

| Soubor | Sekce | Téma |
|---|---|---|
| `supervision-and-otp.md` | §2 | Supervision tree + per-node rationale + OTP pro lidi z Next.js |
| `data-flow.md` | §3 | End-to-end datový tok (HTTP → SGS → Broadway → Ledger) |
| `hash-chain.md` | §5 | Hash-chain invariant + epoch boundary |
| `broadway-pipeline.md` | §6 | Broadway producer/consumer, concurrency, retry |
| `eval-and-replay.md` | §7 | Eval Framework + Cassettes/Replay + web UI vrstvy |
| `testing-otp.md` | §8 | Test architektura (jak testujeme OTP) |
| `sdk-contract.md` | §9 | SDK kontrakt (Python + TypeScript) |
| `open-questions.md` | §10 | Open otázky + known limitations + known gaps |

Každý soubor začíná `<!-- Source: architecture-map.md §N — Title -->` parent headerem.
Plná **Modul-Dependency Matrix (§4)** zůstává fyzicky v `../architecture-map.md`
(čte ji `test/span_chain/docs_test.exs`).
