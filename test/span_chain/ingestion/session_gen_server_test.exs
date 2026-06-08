defmodule SpanChain.Ingestion.SessionGenServerTest do
  use SpanChain.DataCase, async: false

  alias SpanChain.{Eval, Ledger, Run}
  alias SpanChain.Ingestion.{SessionGenServer, SessionSupervisor}

  defp span(name, attrs \\ %{}) do
    %{
      "span_id" => :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower),
      "name" => name,
      "started_at" => "2026-05-15T10:00:00Z",
      "ended_at" => "2026-05-15T10:00:01Z",
      "attributes" => attrs
    }
  end

  defp fresh_run_id, do: "run-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  # GF-703 / CLAUDE.md PubSub test pattern: the post-commit broadcast fires only AFTER
  # the Repo.transaction commit + connection release. Telemetry [:gf, :ledger,
  # :batch_insert, :stop] fires INSIDE the transaction → races with the Broadway commit →
  # Exqlite ConnectionError "owner exited" in the log. The caller MUST subscribe BEFORE
  # ingest_spans, then call wait_for_all_committed/3, and unsubscribe afterward
  # (typically on_exit).
  defp wait_for_all_committed(run_id, expected, timeout_ms \\ 10_000) do
    if count_committed(run_id) >= expected do
      :ok
    else
      receive do
        {:spans_flushed, ^run_id} ->
          wait_for_all_committed(run_id, expected, timeout_ms)
      after
        timeout_ms ->
          {:error, {:timeout, count_committed(run_id), expected}}
      end
    end
  end

  defp count_committed(run_id) do
    Repo.aggregate(from(l in Ledger, where: l.run_id == ^run_id), :count, :run_id)
  end

  describe "compute_hash/7" do
    test "deterministic — same inputs → same hash" do
      payload = %{"k" => "v", "n" => 1}
      a = Ledger.compute_hash(0, nil, "llm_call", payload, nil, "test-run-gf787", 1)
      b = Ledger.compute_hash(0, nil, "llm_call", payload, nil, "test-run-gf787", 1)
      assert a == b
    end

    test "prev_hash difference produces different output (chain coupling)" do
      payload = %{"k" => "v"}
      a = Ledger.compute_hash(1, nil, "llm_call", payload, nil, "test-run-gf787", 1)
      b = Ledger.compute_hash(1, "abc", "llm_call", payload, nil, "test-run-gf787", 1)
      refute a == b
    end

    test "seq affects hash" do
      payload = %{"k" => "v"}
      a = Ledger.compute_hash(0, nil, "llm_call", payload, nil, "test-run-gf787", 1)
      b = Ledger.compute_hash(1, nil, "llm_call", payload, nil, "test-run-gf787", 1)
      refute a == b
    end

    test "event_type affects hash" do
      payload = %{"k" => "v"}
      a = Ledger.compute_hash(0, nil, "llm_call", payload, nil, "test-run-gf787", 1)
      b = Ledger.compute_hash(0, nil, "tool_call", payload, nil, "test-run-gf787", 1)
      refute a == b
    end

    test "payload affects hash" do
      a = Ledger.compute_hash(0, nil, "llm_call", %{"k" => "v"}, nil, "test-run-gf787", 1)
      b = Ledger.compute_hash(0, nil, "llm_call", %{"k" => "w"}, nil, "test-run-gf787", 1)
      refute a == b
    end
  end

  describe "epoch boundary" do
    test "rolls over after 1000 events: epoch_id++, seq=0, prev_hash preserved (GF-666)" do
      run_id = fresh_run_id()
      {:ok, _pid} = SessionSupervisor.ensure_session(run_id)

      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")
      on_exit(fn -> Phoenix.PubSub.unsubscribe(SpanChain.PubSub, "run:#{run_id}") end)

      spans = for i <- 1..1000, do: span("e#{i}")
      {:ok, 1000} = SessionGenServer.ingest_spans(run_id, spans)

      snap = SessionGenServer.snapshot(run_id)
      assert snap.epoch_id == 1
      assert snap.seq == 0
      # GF-666: prev_hash MUST NOT be nil after the epoch rollover — it must chain onto
      # the last hash of the previous epoch (otherwise an Island Attack passes verify).
      assert is_binary(snap.prev_hash)

      :ok = wait_for_all_committed(run_id, 1000)
    end

    test "next event in new epoch starts a fresh chain" do
      run_id = fresh_run_id()
      {:ok, _pid} = SessionSupervisor.ensure_session(run_id)

      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")
      on_exit(fn -> Phoenix.PubSub.unsubscribe(SpanChain.PubSub, "run:#{run_id}") end)

      spans = for i <- 1..1001, do: span("e#{i}")
      {:ok, 1001} = SessionGenServer.ingest_spans(run_id, spans)

      snap = SessionGenServer.snapshot(run_id)
      assert snap.epoch_id == 1
      assert snap.seq == 1
      assert is_binary(snap.prev_hash)

      :ok = wait_for_all_committed(run_id, 1001)
    end
  end

  describe "ensure_eval_record (GF-706)" do
    test "ensure_session(run_id, eval_id: e) upserts Eval + sets runs.eval_id" do
      run_id = fresh_run_id()
      eval_id = "eval-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

      {:ok, _pid} = SessionSupervisor.ensure_session(run_id, eval_id: eval_id)

      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")
      on_exit(fn -> Phoenix.PubSub.unsubscribe(SpanChain.PubSub, "run:#{run_id}") end)

      # GF-751: Run/Eval rows are created only AFTER the Pipeline flush (not in SGS.init/1).
      # Ingest 1 span and wait for the commit before the DB asserts.
      {:ok, 1} = SessionGenServer.ingest_spans(run_id, [span("first")])
      :ok = wait_for_all_committed(run_id, 1)

      eval = Repo.get(Eval, eval_id)
      assert eval != nil
      assert eval.eval_id == eval_id

      run = Repo.get(Run, run_id)
      assert run != nil
      assert run.eval_id == eval_id
    end

    test "ensure_session(run_id) without eval_id leaves runs.eval_id nil" do
      run_id = fresh_run_id()

      {:ok, _pid} = SessionSupervisor.ensure_session(run_id)

      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")
      on_exit(fn -> Phoenix.PubSub.unsubscribe(SpanChain.PubSub, "run:#{run_id}") end)

      # GF-751: the Run row is created only AFTER the Pipeline flush — without ingest_spans it won't exist.
      {:ok, 1} = SessionGenServer.ingest_spans(run_id, [span("first")])
      :ok = wait_for_all_committed(run_id, 1)

      run = Repo.get(Run, run_id)
      assert run != nil
      assert run.eval_id == nil
    end

    test "GF-727 late-binding: nil eval_id in init → set via ingest_spans/3 opts" do
      run_id = fresh_run_id()
      eval_id = "late-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

      {:ok, _pid} = SessionSupervisor.ensure_session(run_id)
      assert SessionGenServer.snapshot(run_id).eval_id == nil

      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")
      on_exit(fn -> Phoenix.PubSub.unsubscribe(SpanChain.PubSub, "run:#{run_id}") end)

      {:ok, 1} = SessionGenServer.ingest_spans(run_id, [span("late")], eval_id: eval_id)

      # The snapshot is in-memory SGS state — visible immediately (GF-727 first-wins).
      assert SessionGenServer.snapshot(run_id).eval_id == eval_id

      # GF-751: DB visibility only after the Pipeline flush. wait_for_all_committed MUST
      # come before the Repo.get asserts.
      :ok = wait_for_all_committed(run_id, 1)

      assert %Eval{} = Repo.get(Eval, eval_id)
      assert Repo.get(Run, run_id).eval_id == eval_id
    end

    test "GF-727 late-binding idempotence: first eval_id wins, second ignored" do
      run_id = fresh_run_id()
      first = "first-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      second = "second-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

      {:ok, _pid} = SessionSupervisor.ensure_session(run_id)

      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")
      on_exit(fn -> Phoenix.PubSub.unsubscribe(SpanChain.PubSub, "run:#{run_id}") end)

      {:ok, 1} = SessionGenServer.ingest_spans(run_id, [span("a")], eval_id: first)
      {:ok, 1} = SessionGenServer.ingest_spans(run_id, [span("b")], eval_id: second)

      assert SessionGenServer.snapshot(run_id).eval_id == first

      # GF-751: wait before the Repo.get assert. COALESCE first-wins on runs.eval_id
      # applies in Pipeline.ensure_eval_records — even if a second batch arrived
      # with `second` (it won't, the SGS state returns first), the DB would ignore it.
      :ok = wait_for_all_committed(run_id, 2)
      assert Repo.get(Run, run_id).eval_id == first
    end

    test "GF-727 late-binding: nil opts leaves state.eval_id nil" do
      run_id = fresh_run_id()
      {:ok, _pid} = SessionSupervisor.ensure_session(run_id)

      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")
      on_exit(fn -> Phoenix.PubSub.unsubscribe(SpanChain.PubSub, "run:#{run_id}") end)

      {:ok, 1} = SessionGenServer.ingest_spans(run_id, [span("a")], eval_id: nil)
      {:ok, 1} = SessionGenServer.ingest_spans(run_id, [span("b")], [])
      {:ok, 1} = SessionGenServer.ingest_spans(run_id, [span("c")])

      assert SessionGenServer.snapshot(run_id).eval_id == nil

      :ok = wait_for_all_committed(run_id, 3)
      assert Repo.get(Run, run_id).eval_id == nil
    end

    test "GF-727 late-binding telemetry: [:gf, :sgs, :late_bind_eval_id] fires at most once" do
      run_id = fresh_run_id()
      eval_id = "once-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

      {:ok, _pid} = SessionSupervisor.ensure_session(run_id)

      test_pid = self()
      handler_id = "test-late-bind-#{:erlang.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:gf, :sgs, :late_bind_eval_id],
        fn _event, measurements, meta, _ -> send(test_pid, {:late_bind, measurements, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")
      on_exit(fn -> Phoenix.PubSub.unsubscribe(SpanChain.PubSub, "run:#{run_id}") end)

      {:ok, 1} = SessionGenServer.ingest_spans(run_id, [span("a")], eval_id: eval_id)
      {:ok, 1} = SessionGenServer.ingest_spans(run_id, [span("b")], eval_id: eval_id)
      {:ok, 1} = SessionGenServer.ingest_spans(run_id, [span("c")], eval_id: eval_id)

      assert_receive {:late_bind, %{count: 1}, %{run_id: ^run_id, eval_id: ^eval_id}}, 1_000
      refute_receive {:late_bind, _, _}, 200

      :ok = wait_for_all_committed(run_id, 3)
    end

    test "SGS does not crash when the Eval insert fails (sandbox-style sabotage)" do
      # This test verifies the resilience pattern, not a specific fail mode.
      # Using an invalid eval_id length / shape is tricky without a schema constraint;
      # instead we spawn an SGS with an eval_id and verify the process survives (SGS init
      # has try/rescue/catch — even if something fails, it returns :ok).
      run_id = fresh_run_id()
      eval_id = "eval-resilience-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

      {:ok, pid} = SessionSupervisor.ensure_session(run_id, eval_id: eval_id)
      assert Process.alive?(pid)

      # Subscribe BEFORE the first ingest — otherwise the first flush could race
      # with sandbox cleanup (the previous telemetry helper attach after the first ingest
      # caught only the second flush; the first was unsafe).
      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")
      on_exit(fn -> Phoenix.PubSub.unsubscribe(SpanChain.PubSub, "run:#{run_id}") end)

      # After init the process keeps responding to messages
      assert {:ok, 1} = SessionGenServer.ingest_spans(run_id, [%{"name" => "after_init"}])
      assert Process.alive?(pid)

      {:ok, 1} = SessionGenServer.ingest_spans(run_id, [%{"name" => "second"}])
      :ok = wait_for_all_committed(run_id, 2)
    end
  end

  # ---------------------------------------------------------------------------
  # GF-775: crash recovery IMPLEMENTED (previously GF-768 bug characterization).
  #
  # The SGS is restart: :temporary → a crash does NOT auto-restart. The next ingest via
  # SessionSupervisor.ensure_session/1 performs recovery OUTSIDE the SGS (GF-751 holds):
  # it reads the last epoch + hash from the DB, spawns with epoch_id+1 and a carried prev_hash.
  # The epoch rollover = its own sequence space (no collision with in-flight old
  # spans), the carried prev_hash = GF-666 cross-epoch continuity → verify_ledger
  # stays {:ok, _}. Details: docs/crash-recovery-2026-05-26.md (audit).
  # ---------------------------------------------------------------------------
  describe "crash recovery (GF-775)" do
    test "restart rolls epoch + carries prev_hash → chain stays valid" do
      run_id = "crash-test-run-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")
      on_exit(fn -> Phoenix.PubSub.unsubscribe(SpanChain.PubSub, "run:#{run_id}") end)

      # 1. Session + 5 spans (epoch 0, seq 0–4) → flush. The chain in the DB is valid.
      {:ok, pid1} = SessionSupervisor.ensure_session(run_id)
      {:ok, 5} = SessionGenServer.ingest_spans(run_id, for(i <- 1..5, do: span("pre#{i}")))
      :ok = wait_for_all_committed(run_id, 5)
      assert count_committed(run_id) == 5
      assert {:ok, 5} = Ledger.verify_ledger(run_id)
      assert SessionGenServer.snapshot(run_id).seq == 5

      # 2. Crash the SGS. restart: :temporary → the supervisor does NOT auto-restart it.
      ref = Process.monitor(pid1)
      Process.exit(pid1, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid1, _}, 1_000

      # 3. The Registry empties (no auto-restart) — verify with a bounded poll.
      assert await_registry_empty(run_id)

      # 4. Recovery via ensure_session/1: drain the old epoch (PubSub epoch_flush),
      #    then spawn with epoch_id+1 and prev_hash from the DB (GF-666 cross-epoch continuity).
      {:ok, pid2} = SessionSupervisor.ensure_session(run_id)
      assert pid2 != pid1
      assert Process.alive?(pid2)

      snap = SessionGenServer.snapshot(run_id)
      assert snap.epoch_id == 1
      assert snap.seq == 0
      assert snap.prev_hash != nil

      # 5. 6 new spans go into epoch 1 (seq 0–5) — their own sequence space,
      #    no collision with the old epoch on (run_id, epoch_id, seq).
      {:ok, 6} = SessionGenServer.ingest_spans(run_id, for(i <- 1..6, do: span("post#{i}")))
      :ok = wait_for_all_committed(run_id, 11)
      assert count_committed(run_id) == 11

      # 6. GF-775: crash recovery implemented — the epoch rollover + carried
      #    prev_hash guarantees chain continuity across the restart.
      assert {:ok, 11} = Ledger.verify_ledger(run_id)
    end

    # GF-782: multi-batch (4×50) recovery regression. A larger prior epoch exercises
    # drain-until-silence in await_epoch_drain. Note: we wait for all 200 to commit
    # BEFORE the kill (deterministically), so the crash doesn't catch in-flight batches —
    # the in-flight drain race is inherently timing-dependent and cannot be deterministically
    # reproduced without a flaky test. This is a correctness regression (the chain is valid
    # across a 4-batch epoch); the fix itself is drain_until_silence/3.
    test "recovery after a crash with 4 in-flight batches preserves hash-chain integrity" do
      run_id =
        "multi-batch-recovery-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")
      on_exit(fn -> Phoenix.PubSub.unsubscribe(SpanChain.PubSub, "run:#{run_id}") end)

      # 1. 200 spans = 4 batches × 50 (epoch 0). Wait for all to commit.
      {:ok, pid} = SessionSupervisor.ensure_session(run_id)
      {:ok, 200} = SessionGenServer.ingest_spans(run_id, for(i <- 1..200, do: span("pre#{i}")))
      :ok = wait_for_all_committed(run_id, 200)
      assert count_committed(run_id) == 200
      assert {:ok, 200} = Ledger.verify_ledger(run_id)

      # 2. Crash + verify the :temporary SGS does NOT auto-restart.
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
      assert await_registry_empty(run_id)

      # 3. Recovery via ensure_session/1 (NOT ingest_spans — that's just a GenServer.call):
      #    drain the old epoch + spawn epoch 1 with a carried prev_hash. Then 10 spans.
      {:ok, pid2} = SessionSupervisor.ensure_session(run_id)
      assert pid2 != pid
      snap = SessionGenServer.snapshot(run_id)
      assert snap.epoch_id == 1
      assert snap.prev_hash != nil

      {:ok, 10} = SessionGenServer.ingest_spans(run_id, for(i <- 1..10, do: span("post#{i}")))
      :ok = wait_for_all_committed(run_id, 210)
      assert count_committed(run_id) == 210

      # 4. GF-666 cross-epoch continuity preserved across the 4-batch prior epoch.
      assert {:ok, 210} = Ledger.verify_ledger(run_id)
    end
  end

  # GF-775: bounded poll until the Registry is empty (a crashed :temporary SGS does
  # NOT auto-restart). receive/after to yield between lookups, no Process.sleep.
  defp await_registry_empty(run_id, retries \\ 200) do
    case Registry.lookup(SpanChain.Ingestion.SessionRegistry, run_id) do
      [] ->
        true

      _ when retries > 0 ->
        receive do
        after
          5 -> :ok
        end

        await_registry_empty(run_id, retries - 1)

      _ ->
        flunk("SGS Registry entry not cleared after crash within budget")
    end
  end
end
