# arch/ — detailed architecture sections

These files hold the **detailed prose** split out of `../architecture-map.md`. The main
`architecture-map.md` stays a hub: §1 overview + stub sections + the full §4 Dependency
Matrix. The detail of each section lives here.

| File | Section | Topic |
|---|---|---|
| `supervision-and-otp.md` | §2 | Supervision tree + per-node rationale + OTP for people from Next.js |
| `data-flow.md` | §3 | End-to-end data flow (HTTP → SGS → Broadway → Ledger) |
| `hash-chain.md` | §5 | Hash-chain invariant + epoch boundary |
| `broadway-pipeline.md` | §6 | Broadway producer/consumer, concurrency, retry |
| `eval-and-replay.md` | §7 | Eval Framework + Cassettes/Replay + web UI layers |
| `testing-otp.md` | §8 | Test architecture (how we test OTP) |
| `sdk-contract.md` | §9 | SDK contract (Python + TypeScript) |
| `open-questions.md` | §10 | Open questions + known limitations + known gaps |

Each file starts with a `<!-- Source: architecture-map.md §N — Title -->` parent header.
The full **Module Dependency Matrix (§4)** stays physically in `../architecture-map.md`
(read by `test/span_chain/docs_test.exs`).
