<!-- Source: architecture-map.md §3 — Data flow (end-to-end flow) -->

## 3. Data flow — end-to-end flow

```
1.  HTTP POST /ingest         (Bandit, port 4000)
        │
2.  Ingestion.AuthPlug.call/2 (auth_plug.ex:11-26)
        │  bearer header check, Plug.Crypto.secure_compare → fail-closed
        │  /health bypass, otherwise 401 + halt
        │
3.  Plug.Parsers JSON         (router.ex:12-15)
        │
4.  match → POST "/ingest"    (router.ex:20-25)
        │  :telemetry.span [:gf, :ingest, :request]
        │
5.  validate/1                (router.ex:107-118)
        │  {:ok, run_id, spans} | {:error, :invalid_*}
        │
6.  SessionSupervisor.ensure_session(run_id, opts)   (session_supervisor.ex:26-34)
        │  Registry.lookup → existing pid? return.
        │  otherwise spawn_session/2 → DynamicSupervisor.start_child
        │  → SessionGenServer.init/1:
        │       state = %{run_id, eval_id, epoch_id: 0, seq: 0, prev_hash: nil}
        │       (after GF-751/GF-746 + commit `9c7f03c`: NO DB access;
        │        runs/evals upserts moved into Pipeline.handle_batch)
        │
7.  SessionGenServer.ingest_spans(run_id, spans)    (session_gen_server.ex:80-86)
        │  GenServer.call → mailbox FIFO → handle_call({:ingest_spans, spans})
        │
8.  build_entries/2          (session_gen_server.ex:138-149)
        │  Enum.reduce over spans:
        │    Ledger.build_entry/7 — compute_hash + entry map
        │    append_span/2 attaches state.eval_id to the entry as an in-memory `:eval_id`
        │       sidecar (GF-751; the Pipeline strips it before Ledger.insert_batch)
        │    state {prev_hash, seq, epoch_id} mutated
        │    maybe_epoch_boundary (seq % 1000 == 0 → epoch_id++, seq=0, prev_hash kept GF-666)
        │
9.  BufferProducer.enqueue(entries)  (buffer_producer.ex:54-59)
        │  Registry.lookup(BufferRegistry, :singleton) → cast {:enqueue, entries}
        │  fire-and-forget (NO blocking on Broadway side)
        │
10. SGS returns {:ok, length(spans)} → Router puts 202 Accepted response
        │   (HTTP request returns at this point — milliseconds after step 1)
        │
                ───── ASYNC BOUNDARY ─────
        ▼
11. BufferProducer.handle_cast({:enqueue, ...})  (buffer_producer.ex:83-87)
        │  wraps entries → %Broadway.Message{} (NoopAcknowledger)
        │  pushes to :queue, calls dispatch/1
        │
12. Broadway demand pull model
        │  Producer waits for handle_demand from Processor
        │  Processor pulls up to N (batch_size), Batcher accumulates by size/timeout
        │
13. Pipeline.handle_batch(:default, messages, _, _)  (pipeline.ex:72-130)
        │  entries = Enum.map(messages, & &1.data)
        │  (GF-751/GF-746 metadata phase — BEFORE the ledger insert, defensive rescue):
        │    ensure_run_records(entries)     # Repo.insert_all "runs"  on_conflict :nothing
        │    ensure_eval_records(entries)    # Repo.insert_all "evals" + COALESCE update runs.eval_id
        │    upsert_agent_configs(entries)   # GF-748 gf.agent.* projection
        │  ledger_entries = Enum.map(entries, &Map.delete(&1, :eval_id))  # strip SGS sidecar
        │  with_retry/3 (private, pipeline.ex:197-224):
        │    Repo.transaction(fn -> ledger_mod.insert_batch(ledger_entries) end)
        │    on raise → catch → {:error, reason} → retry up to 3× exp backoff (500/1000/2000 ms prod, 1ms test)
        │
14a. Success path
        │  broadcast_flushed/1 (pipeline.ex:114-119) — CALLED LAST (after metadata + ledger commit)
        │    Phoenix.PubSub.broadcast → "run:#{run_id}" → {:spans_flushed, run_id}
        │    Phoenix.PubSub.broadcast → "runs"         → {:run_updated,  run_id}
        │  TrailLive.handle_info/2 re-fetches view (trail_live.ex:64-78)
        │  Cassettes.Replayer waits on this signal (replayer.ex:64-77)
        │
14b. Failure path (retry exhausted)
        │  Pipeline returns Enum.map(messages, &Message.failed/2)
        │  Broadway → Pipeline.handle_failed/2 (pipeline.ex:148-188)
        │  DeadLetter.store(run_id, [entry], reason) (dead_letter.ex:54-83)
        │  :telemetry.execute [:gf, :flush, :dead_letter]
        │  hash chain in Ledger continues with gaps → verify_ledger detects
```

Shortened ASCII version (as in the prompt task):

```
HTTP POST /ingest
  → AuthPlug (bearer check)
  → Plug.Parsers (JSON)
  → Router.handle_ingest/1 → validate
  → SessionSupervisor.ensure_session/2
      → Registry.lookup → spawn (DynamicSupervisor) | reuse
  → SessionGenServer.handle_call({:ingest_spans, spans})
      → build_entries → Ledger.compute_hash per span
      → BufferProducer.enqueue (cast, async)
  → returns 202 + {accepted, run_id}
        ─── ASYNC ───
  → BufferProducer (GenStage demand) → Broadway Pipeline
      → handle_batch → with_retry/3 → Repo.transaction → Ledger.insert_batch/1
          ├─ ok   → Phoenix.PubSub.broadcast → TrailLive update + Replayer signal
          └─ fail → Message.failed → handle_failed → DeadLetter.store/3
```

The OTLP/HTTP JSON path (`POST /v1/traces`) has an identical downstream — it only
prepends the step `OtlpTranslator.translate/1` (`router.ex:82-105`), which converts
the `resourceSpans` JSON into the internal span shape + extracts `run_id` from
`service.instance.id` + `eval_id` from the `gf.eval_id` resource attribute.

---

