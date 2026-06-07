defmodule SpanChain.LedgerTest do
  use SpanChain.DataCase, async: false

  alias SpanChain.Ingestion.{SessionGenServer, SessionSupervisor}
  alias SpanChain.Ledger

  defp span(name, extra) do
    Map.merge(
      %{
        "span_id" => :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower),
        "name" => name,
        "started_at" => "2026-05-16T10:00:00Z",
        "ended_at" => "2026-05-16T10:00:01Z",
        "attributes" => %{}
      },
      extra
    )
  end

  defp fresh_run_id, do: "gf652-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  # GF-667: ingest je nyní async přes Broadway. Helper attachne telemetry před
  # ingest_spans, akumuluje `count` z [:gf, :ledger, :batch_insert, :stop] eventů,
  # vrací :ok jakmile dosáhne `expected_total` (nebo {:error, :timeout}).
  defp attach_total_wait(test_pid) do
    ref = make_ref()
    handler_id = "gf-total-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      [:gf, :ledger, :batch_insert, :stop],
      fn _e, %{count: count}, _md, _ -> send(test_pid, {:flushed_count, ref, count}) end,
      nil
    )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  defp wait_for_total(ref, expected, timeout_ms \\ 5_000) do
    do_wait_total(ref, 0, expected, timeout_ms)
  end

  defp do_wait_total(_ref, acc, expected, _timeout) when acc >= expected, do: :ok

  defp do_wait_total(ref, acc, expected, timeout_ms) do
    receive do
      {:flushed_count, ^ref, count} ->
        do_wait_total(ref, acc + count, expected, timeout_ms)
    after
      timeout_ms ->
        {:error, {:timeout, acc, expected}}
    end
  end

  describe "compute_hash/7 — parent_span_id + run/epoch v hashi" do
    test "stejný event s různým parent_span_id → různý hash (tamper-evidence)" do
      seq = 1
      prev = "abc"
      event = "llm_call"
      payload = %{"k" => "v"}
      run_id = "test-run-gf787"
      epoch = 1

      h_nil = Ledger.compute_hash(seq, prev, event, payload, nil, run_id, epoch)
      h_s1 = Ledger.compute_hash(seq, prev, event, payload, "s1", run_id, epoch)
      h_s2 = Ledger.compute_hash(seq, prev, event, payload, "s2", run_id, epoch)

      refute h_nil == h_s1
      refute h_s1 == h_s2
      refute h_nil == h_s2
    end

    test "run_id a epoch_id jsou v hashi (GF-787 — entry vázána ke svému runu/epoše)" do
      base = Ledger.compute_hash(0, nil, "x", %{}, nil, "run-a", 0)
      diff_run = Ledger.compute_hash(0, nil, "x", %{}, nil, "run-b", 0)
      diff_epoch = Ledger.compute_hash(0, nil, "x", %{}, nil, "run-a", 1)

      refute base == diff_run
      refute base == diff_epoch
    end

    test "explicit Integer.to_string casts produce identical hash (GF-812 regression)" do
      # baseline computed before refactor — must not change
      assert Ledger.compute_hash(1, "abc", "evt", ~s|{}|, nil, "run-1", 42) ==
               "f66eaf6bb443ae666e045ba39fe32c06c30165304b34441aa5a5fc5dbadbe60a"
    end
  end

  describe "compute_hash/7 — canonical JSON (GF-654)" do
    test "hash je deterministický nezávisle na pořadí klíčů v top-level + vnořených mapách + mapách uvnitř pole" do
      # llm_call payload (viz docs/payload-schemas.md): input je array of maps,
      # decision je nested map. Insertion order liší se na všech třech úrovních.
      payload_a = %{
        "model" => "claude-sonnet-4-6",
        "input" => [
          %{"role" => "system", "content" => "You are helpful."},
          %{"role" => "user", "content" => "Should I deploy?"}
        ],
        "decision" => %{"action" => "ask_clarifying", "next_question" => "How risky?"},
        "success" => true
      }

      payload_b = %{
        "success" => true,
        "decision" => %{"next_question" => "How risky?", "action" => "ask_clarifying"},
        "input" => [
          %{"content" => "You are helpful.", "role" => "system"},
          %{"content" => "Should I deploy?", "role" => "user"}
        ],
        "model" => "claude-sonnet-4-6"
      }

      assert Ledger.compute_hash(0, nil, "llm_call", payload_a, nil, "test-run-gf787", 1) ==
               Ledger.compute_hash(0, nil, "llm_call", payload_b, nil, "test-run-gf787", 1)
    end
  end

  describe "build_entry trace_id projection (GF-653)" do
    test "snake_case extraction — /ingest JSON cesta" do
      entry =
        Ledger.build_entry("run-1", 0, 0, nil, "llm_call", %{"trace_id" => "abc123"})

      assert entry.trace_id == "abc123"
    end

    test "camelCase fallback — defenzivní pro nepřekládané zdroje" do
      entry =
        Ledger.build_entry("run-1", 0, 0, nil, "llm_call", %{"traceId" => "def456"})

      assert entry.trace_id == "def456"
    end

    test "nil pokud chybí v payloadu" do
      entry = Ledger.build_entry("run-1", 0, 0, nil, "llm_call", %{"name" => "x"})
      assert entry.trace_id == nil
    end
  end

  describe "persistence parent_span_id" do
    setup do
      ref = make_ref()
      test_pid = self()

      handler_id = "gf652-flush-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:gf, :ledger, :batch_insert, :stop],
        fn _e, m, _md, _ -> send(test_pid, {:flushed, ref, m}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      {:ok, ref: ref}
    end

    test "span s parent_span_id se uloží a načte zpět přes Repo.all/1", %{ref: ref} do
      run_id = fresh_run_id()
      {:ok, pid} = SessionSupervisor.ensure_session(run_id)
      Ecto.Adapters.SQL.Sandbox.allow(SpanChain.Repo, self(), pid)

      spans =
        for i <- 0..49 do
          parent = if i == 0, do: nil, else: "span-#{i - 1}"
          span("step-#{i}", %{"span_id" => "span-#{i}", "parent_span_id" => parent})
        end

      SessionGenServer.ingest_spans(run_id, spans)
      assert_receive {:flushed, ^ref, %{count: 50}}, 2_000

      rows =
        from(l in Ledger, where: l.run_id == ^run_id, order_by: [asc: l.seq])
        |> Repo.all()

      assert length(rows) == 50
      assert Enum.at(rows, 0).parent_span_id == nil
      assert Enum.at(rows, 1).parent_span_id == "span-0"
      assert Enum.at(rows, 49).parent_span_id == "span-48"
    end
  end

  describe "verify_ledger/1" do
    setup do
      ref = make_ref()
      test_pid = self()
      handler_id = "gf652-verify-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:gf, :ledger, :batch_insert, :stop],
        fn _e, m, _md, _ -> send(test_pid, {:flushed, ref, m}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      {:ok, ref: ref}
    end

    test "vrátí count=0 pro neznámý run_id" do
      assert {:ok, 0} = Ledger.verify_ledger("does-not-exist")
    end

    test "vrátí count pro čerstvě napsaný chain", %{ref: ref} do
      run_id = fresh_run_id()
      {:ok, pid} = SessionSupervisor.ensure_session(run_id)
      Ecto.Adapters.SQL.Sandbox.allow(SpanChain.Repo, self(), pid)

      spans = for i <- 0..49, do: span("e-#{i}", %{"parent_span_id" => "p-#{i}"})
      SessionGenServer.ingest_spans(run_id, spans)
      assert_receive {:flushed, ^ref, %{count: 50}}, 2_000

      assert {:ok, 50} = Ledger.verify_ledger(run_id)
    end

    test "odhalí přímou změnu parent_span_id v DB → {:error, :chain_broken}", %{ref: ref} do
      run_id = fresh_run_id()
      {:ok, pid} = SessionSupervisor.ensure_session(run_id)
      Ecto.Adapters.SQL.Sandbox.allow(SpanChain.Repo, self(), pid)

      spans =
        for i <- 0..49 do
          parent = if i == 0, do: nil, else: "span-#{i - 1}"
          span("step-#{i}", %{"span_id" => "span-#{i}", "parent_span_id" => parent})
        end

      SessionGenServer.ingest_spans(run_id, spans)
      assert_receive {:flushed, ^ref, %{count: 50}}, 2_000

      assert {:ok, 50} = Ledger.verify_ledger(run_id)

      # Simuluj tamper: přepiš parent_span_id u jednoho řádku přímo v DB,
      # bez přepočítání hashe → chain musí prasknout.
      {1, _} =
        from(l in Ledger, where: l.run_id == ^run_id and l.seq == 5)
        |> Repo.update_all(set: [parent_span_id: "tampered-value"])

      assert {:error, :chain_broken} = Ledger.verify_ledger(run_id)
    end
  end

  describe "verify_ledger/1 cross-epoch continuity (GF-666)" do
    test "1001 spans přes SGS: epoch 1 first entry má prev_hash != nil, verify {:ok, 1001}" do
      run_id = fresh_run_id()
      {:ok, pid} = SessionSupervisor.ensure_session(run_id)
      Ecto.Adapters.SQL.Sandbox.allow(SpanChain.Repo, self(), pid)

      ref = attach_total_wait(self())

      spans = for i <- 1..1001, do: span("e-#{i}", %{})
      {:ok, 1001} = SessionGenServer.ingest_spans(run_id, spans)

      :ok = wait_for_total(ref, 1001, 10_000)

      rows =
        from(l in Ledger,
          where: l.run_id == ^run_id,
          order_by: [asc: l.epoch_id, asc: l.seq]
        )
        |> Repo.all()

      assert length(rows) == 1001

      first_epoch_1 = Enum.find(rows, fn r -> r.epoch_id == 1 and r.seq == 0 end)
      assert first_epoch_1 != nil
      assert is_binary(first_epoch_1.prev_hash)
      refute first_epoch_1.prev_hash == nil

      assert {:ok, 1001} = Ledger.verify_ledger(run_id)
    end

    test "Island Attack: smazání prostřední epochy rozbije chain → {:error, :chain_broken}" do
      run_id = fresh_run_id()

      # 3 epochy x 3 záznamy, chain prochází plynule přes epoch hranice
      {entries, _last} =
        Enum.reduce(0..8, {[], nil}, fn i, {acc, prev_hash} ->
          epoch_id = div(i, 3)
          seq_in_epoch = rem(i, 3)

          entry =
            Ledger.build_entry(run_id, epoch_id, seq_in_epoch, prev_hash, "e#{i}", %{"i" => i})

          {acc ++ [entry], entry.hash}
        end)

      {9, _} = Ledger.insert_batch(entries)

      # Sanity: nedotčený chain validuje
      assert {:ok, 9} = Ledger.verify_ledger(run_id)

      # Útok: smaž celou prostřední epochu (vnitřně konzistentní, ale chybí v chainu)
      {3, _} =
        from(l in Ledger, where: l.run_id == ^run_id and l.epoch_id == 1)
        |> Repo.delete_all()

      # epoch 0 last_hash != epoch 2 first prev_hash → detekováno
      assert {:error, :chain_broken} = Ledger.verify_ledger(run_id)
    end
  end
end
