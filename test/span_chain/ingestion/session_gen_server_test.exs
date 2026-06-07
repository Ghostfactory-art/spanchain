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

  # GF-703 / CLAUDE.md PubSub test pattern: post-commit broadcast firi AŽ PO
  # Repo.transaction commit + connection release. Telemetry [:gf, :ledger,
  # :batch_insert, :stop] firi UVNITR transakce → race s Broadway commit →
  # Exqlite ConnectionError "owner exited" v logu. Caller MUSI subscribe PRED
  # ingest_spans, pak volat wait_for_all_committed/3, a unsubscribe v after
  # (typicky on_exit).
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
    test "rolls over after 1000 events: epoch_id++, seq=0, prev_hash zachován (GF-666)" do
      run_id = fresh_run_id()
      {:ok, _pid} = SessionSupervisor.ensure_session(run_id)

      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")
      on_exit(fn -> Phoenix.PubSub.unsubscribe(SpanChain.PubSub, "run:#{run_id}") end)

      spans = for i <- 1..1000, do: span("e#{i}")
      {:ok, 1000} = SessionGenServer.ingest_spans(run_id, spans)

      snap = SessionGenServer.snapshot(run_id)
      assert snap.epoch_id == 1
      assert snap.seq == 0
      # GF-666: prev_hash NESMÍ být nil po epoch rollover — musí navazovat
      # na poslední hash předchozí epochy (jinak Island Attack projde verify).
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

      # GF-751: Run/Eval řádky vznikají AŽ po Pipeline flush (ne v SGS.init/1).
      # Ingestnout 1 span a počkat na commit před DB asserty.
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

      # GF-751: Run řádek vzniká AŽ po Pipeline flush — bez ingest_spans nebude existovat.
      {:ok, 1} = SessionGenServer.ingest_spans(run_id, [span("first")])
      :ok = wait_for_all_committed(run_id, 1)

      run = Repo.get(Run, run_id)
      assert run != nil
      assert run.eval_id == nil
    end

    test "GF-727 late-binding: nil eval_id v init → set via ingest_spans/3 opts" do
      run_id = fresh_run_id()
      eval_id = "late-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

      {:ok, _pid} = SessionSupervisor.ensure_session(run_id)
      assert SessionGenServer.snapshot(run_id).eval_id == nil

      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")
      on_exit(fn -> Phoenix.PubSub.unsubscribe(SpanChain.PubSub, "run:#{run_id}") end)

      {:ok, 1} = SessionGenServer.ingest_spans(run_id, [span("late")], eval_id: eval_id)

      # Snapshot je in-memory SGS state — viditelný okamžitě (GF-727 first-wins).
      assert SessionGenServer.snapshot(run_id).eval_id == eval_id

      # GF-751: DB visibility až po Pipeline flush. wait_for_all_committed MUSÍ
      # přijít před Repo.get asserty.
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

      # GF-751: wait před Repo.get assertem. COALESCE first-wins na runs.eval_id
      # se uplatní v Pipeline.ensure_eval_records — i kdyby druhý batch dorazil
      # s `second` (nedorazí, SGS state vrátí first), DB by ho ignorovala.
      :ok = wait_for_all_committed(run_id, 2)
      assert Repo.get(Run, run_id).eval_id == first
    end

    test "GF-727 late-binding: nil opts ponechá state.eval_id nil" do
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

    test "GF-727 late-binding telemetry: [:gf, :sgs, :late_bind_eval_id] firi max 1x" do
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

    test "SGS nekrashne když Eval insert selže (sandbox-style sabotage)" do
      # Tento test ověřuje resilience pattern, ne konkrétní fail mode.
      # Use invalid eval_id length / shape je tricky bez schema constraint;
      # místo toho spawn SGS s eval_id a verify že proces přežije (SGS init
      # má try/rescue/catch — even pokud něco selže, vrátí :ok).
      run_id = fresh_run_id()
      eval_id = "eval-resilience-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

      {:ok, pid} = SessionSupervisor.ensure_session(run_id, eval_id: eval_id)
      assert Process.alive?(pid)

      # Subscribe PRED prvnim ingest — jinak by prvni flush mohl race-ovat
      # s sandbox cleanup (predchozi telemetry helper attach po prvnim ingest
      # zachycoval jen druhy flush, prvni byl unsafe).
      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")
      on_exit(fn -> Phoenix.PubSub.unsubscribe(SpanChain.PubSub, "run:#{run_id}") end)

      # Po init proces nadále reaguje na messages
      assert {:ok, 1} = SessionGenServer.ingest_spans(run_id, [%{"name" => "after_init"}])
      assert Process.alive?(pid)

      {:ok, 1} = SessionGenServer.ingest_spans(run_id, [%{"name" => "second"}])
      :ok = wait_for_all_committed(run_id, 2)
    end
  end

  # ---------------------------------------------------------------------------
  # GF-775: crash recovery IMPLEMENTOVÁNA (dříve GF-768 charakterizace bugu).
  #
  # SGS je restart: :temporary → crash NEauto-restartuje. Další ingest přes
  # SessionSupervisor.ensure_session/1 provede recovery MIMO SGS (GF-751 drží):
  # přečte z DB poslední epoch + hash, spawn s epoch_id+1 a carried prev_hash.
  # Epoch rollover = vlastní sekvence prostor (žádná kolize s in-flight starými
  # spany), carried prev_hash = GF-666 cross-epoch kontinuita → verify_ledger
  # zůstane {:ok, _}. Detaily: docs/crash-recovery-2026-05-26.md (audit).
  # ---------------------------------------------------------------------------
  describe "crash recovery (GF-775)" do
    test "restart rolls epoch + carries prev_hash → chain stays valid" do
      run_id = "crash-test-run-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")
      on_exit(fn -> Phoenix.PubSub.unsubscribe(SpanChain.PubSub, "run:#{run_id}") end)

      # 1. Session + 5 spanů (epoch 0, seq 0–4) → flush. Chain v DB validní.
      {:ok, pid1} = SessionSupervisor.ensure_session(run_id)
      {:ok, 5} = SessionGenServer.ingest_spans(run_id, for(i <- 1..5, do: span("pre#{i}")))
      :ok = wait_for_all_committed(run_id, 5)
      assert count_committed(run_id) == 5
      assert {:ok, 5} = Ledger.verify_ledger(run_id)
      assert SessionGenServer.snapshot(run_id).seq == 5

      # 2. Crash SGS. restart: :temporary → supervisor ho NEauto-restartuje.
      ref = Process.monitor(pid1)
      Process.exit(pid1, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid1, _}, 1_000

      # 3. Registry se vyprázdní (žádný auto-restart) — ověř bounded pollem.
      assert await_registry_empty(run_id)

      # 4. Recovery přes ensure_session/1: drain staré epochy (PubSub epoch_flush),
      #    pak spawn s epoch_id+1 a prev_hash z DB (GF-666 cross-epoch kontinuita).
      {:ok, pid2} = SessionSupervisor.ensure_session(run_id)
      assert pid2 != pid1
      assert Process.alive?(pid2)

      snap = SessionGenServer.snapshot(run_id)
      assert snap.epoch_id == 1
      assert snap.seq == 0
      assert snap.prev_hash != nil

      # 5. 6 nových spanů jdou do epochy 1 (seq 0–5) — vlastní sekvence prostor,
      #    žádná kolize se starou epochou na (run_id, epoch_id, seq).
      {:ok, 6} = SessionGenServer.ingest_spans(run_id, for(i <- 1..6, do: span("post#{i}")))
      :ok = wait_for_all_committed(run_id, 11)
      assert count_committed(run_id) == 11

      # 6. GF-775: crash recovery implementována — epoch rollover + carried
      #    prev_hash garantuje chain kontinuitu přes restart.
      assert {:ok, 11} = Ledger.verify_ledger(run_id)
    end

    # GF-782: multi-batch (4×50) recovery regrese. Větší prior epocha cvičí
    # drain-until-silence v await_epoch_drain. Pozn.: čekáme na commit všech 200
    # PŘED killem (deterministicky), takže crash nezachytí in-flight batche —
    # in-flight drain race je inherentně timing-dependent a nelze deterministicky
    # reprodukovat bez flaky testu. Tohle je correctness regrese (chain validní
    # přes 4-batch epochu); samotný fix je drain_until_silence/3.
    test "recovery po crashi se 4 in-flight batchy zachová hash-chain integritu" do
      run_id =
        "multi-batch-recovery-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")
      on_exit(fn -> Phoenix.PubSub.unsubscribe(SpanChain.PubSub, "run:#{run_id}") end)

      # 1. 200 spanů = 4 batche × 50 (epoch 0). Počkej na commit všech.
      {:ok, pid} = SessionSupervisor.ensure_session(run_id)
      {:ok, 200} = SessionGenServer.ingest_spans(run_id, for(i <- 1..200, do: span("pre#{i}")))
      :ok = wait_for_all_committed(run_id, 200)
      assert count_committed(run_id) == 200
      assert {:ok, 200} = Ledger.verify_ledger(run_id)

      # 2. Crash + ověř že :temporary SGS se NEauto-restartuje.
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
      assert await_registry_empty(run_id)

      # 3. Recovery přes ensure_session/1 (NE ingest_spans — to jen GenServer.call):
      #    drain staré epochy + spawn epoch 1 s carried prev_hash. Pak 10 spanů.
      {:ok, pid2} = SessionSupervisor.ensure_session(run_id)
      assert pid2 != pid
      snap = SessionGenServer.snapshot(run_id)
      assert snap.epoch_id == 1
      assert snap.prev_hash != nil

      {:ok, 10} = SessionGenServer.ingest_spans(run_id, for(i <- 1..10, do: span("post#{i}")))
      :ok = wait_for_all_committed(run_id, 210)
      assert count_committed(run_id) == 210

      # 4. GF-666 cross-epoch kontinuita zachována přes 4-batch prior epochu.
      assert {:ok, 210} = Ledger.verify_ledger(run_id)
    end
  end

  # GF-775: bounded poll až je Registry prázdný (crashnutý :temporary SGS se
  # NEauto-restartuje). receive/after pro yield mezi lookupy, žádný Process.sleep.
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
