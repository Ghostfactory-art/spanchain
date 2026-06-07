defmodule SpanChain.Ingestion.PipelineTest do
  use SpanChain.DataCase, async: false

  alias SpanChain.Ingestion.BufferProducer
  alias SpanChain.Ledger

  # Pipeline + BufferProducer běží v Application supervision tree v test env
  # (per config/test.exs: start_broadway_pipeline: true, producer_module: BufferProducer).
  # DataCase attachne telemetry handler pro Sandbox.allow na Broadway processory.

  defp fresh_run_id, do: "pipe-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  # Pipeline + BufferProducer jsou singleton v Application supervisor — testy
  # sdílejí pipeline → handler dostává events ze všech paralelních testů.
  # Filtrace na konkrétní `run_id` přes `run_ids` v metadata izoluje events.
  defp attach_flush_handler(run_id) do
    test_pid = self()
    ref = make_ref()
    handler_id = "pipe-flush-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      [:gf, :ledger, :batch_insert, :stop],
      fn _e, m, %{run_ids: run_ids}, _ ->
        if run_id in run_ids, do: send(test_pid, {:flushed, ref, m})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  test "BufferProducer.enqueue → Pipeline.handle_batch → row v DB (happy path)" do
    run_id = fresh_run_id()
    ref = attach_flush_handler(run_id)

    entry = Ledger.build_entry(run_id, 0, 0, nil, "span", %{"x" => 1}, nil)
    :ok = BufferProducer.enqueue([entry])

    # Sdílená Pipeline + parallel test files = batch může obsahovat entries z více
    # run_ids → count v measurements odráží celý batch, ne jen moje. Filter
    # handler vystřelí když je můj run_id v batchi, dál ověřujeme DB.
    assert_receive {:flushed, ^ref, _measurements}, 2_000

    row = Repo.one(from(l in Ledger, where: l.run_id == ^run_id))
    assert row != nil
    assert row.event_type == "span"
    assert row.payload == %{"x" => 1}
  end

  test "GF-790: ledger entry persists status projection from payload" do
    run_id = fresh_run_id()
    ref = attach_flush_handler(run_id)

    payload = %{"span_id" => "s1", "status" => "error", "started_at" => "2026-05-15T10:00:00Z"}
    entry = Ledger.build_entry(run_id, 0, 0, nil, "span", payload, nil)
    # status je projekce vytvořená v build_entry PO compute_hash (hash beze změny).
    assert entry.status == "error"

    :ok = BufferProducer.enqueue([entry])
    assert_receive {:flushed, ^ref, _measurements}, 2_000

    row = Repo.get_by(Ledger, run_id: run_id, epoch_id: 0, seq: 0)
    assert row.status == "error"
  end

  test "ordering — 5 entries pro stejný run_id v seq order po DB roundtripu" do
    run_id = fresh_run_id()
    ref = attach_flush_handler(run_id)

    {entries, _last} =
      Enum.reduce(0..4, {[], nil}, fn i, {acc, prev_hash} ->
        entry = Ledger.build_entry(run_id, 0, i, prev_hash, "e#{i}", %{"i" => i}, nil)
        {acc ++ [entry], entry.hash}
      end)

    :ok = BufferProducer.enqueue(entries)
    assert_receive {:flushed, ^ref, _measurements}, 2_000

    rows =
      from(l in Ledger, where: l.run_id == ^run_id, order_by: [asc: l.seq])
      |> Repo.all()

    assert Enum.map(rows, & &1.seq) == [0, 1, 2, 3, 4]
    # Hash chain je validní po DB roundtripu — verify_ledger ověří kontinuitu
    assert {:ok, 5} = Ledger.verify_ledger(run_id)
  end

  test "batch flush — 50 spans projdou pipeline + jsou v DB" do
    run_id = fresh_run_id()
    ref = attach_flush_handler(run_id)

    {entries, _} =
      Enum.reduce(0..49, {[], nil}, fn i, {acc, prev_hash} ->
        entry = Ledger.build_entry(run_id, 0, i, prev_hash, "e#{i}", %{}, nil)
        {acc ++ [entry], entry.hash}
      end)

    :ok = BufferProducer.enqueue(entries)
    # Počkat dokud kumulativní inserts pro náš run_id ≥ 50 (může to být víc batchů)
    :ok = wait_for_run_count(ref, run_id, 50, 5_000)

    assert Repo.aggregate(from(l in Ledger, where: l.run_id == ^run_id), :count, :id) == 50
  end

  # Pollovat Repo místo dovozování count z events (cleanest).
  defp wait_for_run_count(_ref, run_id, expected, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_count(run_id, expected, deadline)
  end

  defp do_wait_count(run_id, expected, deadline) do
    count = Repo.aggregate(from(l in Ledger, where: l.run_id == ^run_id), :count, :id)

    cond do
      count >= expected ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        {:error, {:timeout, count, expected}}

      true ->
        # OK Process.sleep v integration testech které čekají na external async work
        # (Broadway batch_timeout) — alternativa by byla cumulative receive loop, ale
        # batch obsahuje entries z více tests → count není deterministický.
        Process.sleep(20)
        do_wait_count(run_id, expected, deadline)
    end
  end

  describe "ensure_run_records / ensure_eval_records (GF-751 + GF-746)" do
    alias SpanChain.{Eval, Run}
    alias SpanChain.Ingestion.Pipeline

    defp entry_with(run_id, opts \\ []) do
      payload = Keyword.get(opts, :payload, %{"x" => 1})

      Ledger.build_entry(run_id, 0, 0, nil, "span", payload, nil)
      |> Map.put(:eval_id, Keyword.get(opts, :eval_id))
    end

    test "ensure_run_records inserts new run_id with status running + earliest span started_at" do
      run_id = fresh_run_id() <> "-ensure-run"
      entry = entry_with(run_id, payload: %{"started_at" => "2026-05-15T10:00:00Z"})
      assert Pipeline.ensure_run_records([entry]) == :ok

      run = Repo.get(Run, run_id)
      assert run != nil
      assert run.status == "running"
      # GF-790: started_at je nejstarší span started_at z dávky, ne čas insertu.
      assert DateTime.compare(run.started_at, ~U[2026-05-15 10:00:00Z]) == :eq
    end

    test "ensure_run_records preserves existing run status on conflict (GF-790: only started_at upserted)" do
      run_id = fresh_run_id() <> "-idem-run"
      Repo.insert!(%Run{run_id: run_id, status: "completed"})

      # GF-790: on_conflict aktualizuje POUZE started_at (LEAST) → status "completed"
      # zůstává nedotčený. Druhé volání nesmí hodit.
      assert Pipeline.ensure_run_records([entry_with(run_id)]) == :ok
      assert Repo.get(Run, run_id).status == "completed"
    end

    test "ensure_run_records uses the earliest started_at within a single batch (per-run min)" do
      run_id = fresh_run_id() <> "-batchmin"

      entries = [
        entry_with(run_id, payload: %{"started_at" => "2026-05-15T10:00:07Z"}),
        entry_with(run_id, payload: %{"started_at" => "2026-05-15T10:00:02Z"}),
        entry_with(run_id, payload: %{"started_at" => "2026-05-15T10:00:05Z"})
      ]

      assert Pipeline.ensure_run_records(entries) == :ok
      assert DateTime.compare(Repo.get(Run, run_id).started_at, ~U[2026-05-15 10:00:02Z]) == :eq
    end

    test "ensure_run_records keeps the earliest started_at across batches (LEAST upsert)" do
      run_id = fresh_run_id() <> "-least"

      # Batch 1: started_at 10:00:05
      assert Pipeline.ensure_run_records([
               entry_with(run_id, payload: %{"started_at" => "2026-05-15T10:00:05Z"})
             ]) == :ok

      assert DateTime.compare(Repo.get(Run, run_id).started_at, ~U[2026-05-15 10:00:05Z]) == :eq

      # Batch 2: starší 10:00:01 → LEAST vybere starší hodnotu
      assert Pipeline.ensure_run_records([
               entry_with(run_id, payload: %{"started_at" => "2026-05-15T10:00:01Z"})
             ]) == :ok

      assert DateTime.compare(Repo.get(Run, run_id).started_at, ~U[2026-05-15 10:00:01Z]) == :eq

      # Batch 3: novější 10:00:09 → LEAST drží stávající starší hodnotu
      assert Pipeline.ensure_run_records([
               entry_with(run_id, payload: %{"started_at" => "2026-05-15T10:00:09Z"})
             ]) == :ok

      assert DateTime.compare(Repo.get(Run, run_id).started_at, ~U[2026-05-15 10:00:01Z]) == :eq
    end

    test "ensure_run_records creates rows for multi-run batch" do
      run_a = fresh_run_id() <> "-multi-a"
      run_b = fresh_run_id() <> "-multi-b"
      run_c = fresh_run_id() <> "-multi-c"

      entries = [entry_with(run_a), entry_with(run_b), entry_with(run_a), entry_with(run_c)]
      assert Pipeline.ensure_run_records(entries) == :ok

      assert Repo.get(Run, run_a) != nil
      assert Repo.get(Run, run_b) != nil
      assert Repo.get(Run, run_c) != nil
    end

    test "ensure_eval_records inserts Eval + sets pre-existing Run.eval_id" do
      run_id = fresh_run_id() <> "-eval-set"
      eval_id = "eval-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      Repo.insert!(%Run{run_id: run_id, status: "running"})

      entries = [entry_with(run_id, eval_id: eval_id)]
      assert Pipeline.ensure_eval_records(entries) == :ok

      assert %Eval{eval_id: ^eval_id} = Repo.get(Eval, eval_id)
      assert Repo.get(Run, run_id).eval_id == eval_id
    end

    test "ensure_eval_records is silent no-op for entries without eval_id" do
      run_id = fresh_run_id() <> "-noeval"
      Repo.insert!(%Run{run_id: run_id, status: "running"})

      assert Pipeline.ensure_eval_records([entry_with(run_id)]) == :ok
      assert Repo.get(Run, run_id).eval_id == nil
    end

    test "ensure_eval_records COALESCE first-wins on Run.eval_id" do
      run_id = fresh_run_id() <> "-firstwin"
      first = "first-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      second = "second-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      Repo.insert!(%Run{run_id: run_id, status: "running"})

      assert Pipeline.ensure_eval_records([entry_with(run_id, eval_id: first)]) == :ok
      assert Repo.get(Run, run_id).eval_id == first

      # Druhý batch s jiným eval_id → Eval řádek pro `second` vznikne, ale
      # runs.eval_id zůstane `first` (COALESCE).
      assert Pipeline.ensure_eval_records([entry_with(run_id, eval_id: second)]) == :ok
      assert %Eval{} = Repo.get(Eval, second)
      assert Repo.get(Run, run_id).eval_id == first
    end

    test "handle_batch end-to-end: ensure_runs runs BEFORE insert_batch (Run row present after flush)" do
      run_id = fresh_run_id() <> "-e2e"
      eval_id = "e2e-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      ref = attach_flush_handler(run_id)

      entry = entry_with(run_id, eval_id: eval_id)
      :ok = BufferProducer.enqueue([entry])
      assert_receive {:flushed, ^ref, _measurements}, 2_000

      assert Repo.get(Run, run_id) != nil
      assert Repo.get(Eval, eval_id) != nil
      assert Repo.get(Run, run_id).eval_id == eval_id

      # Ledger entry musí být insertnutá BEZ :eval_id sloupce (jen schema fields).
      ledger_row = Repo.one(from(l in Ledger, where: l.run_id == ^run_id))
      assert ledger_row != nil
      assert ledger_row.event_type == "span"
    end
  end

  describe "upsert_agent_configs (GF-748)" do
    alias SpanChain.Ingestion.Pipeline
    alias SpanChain.Run

    test "extract_agent_config returns config when entries contain gf.agent.* attrs" do
      entry = %Ledger{
        run_id: "test-extract-1",
        payload: %{
          "attributes" => %{
            "gf.agent.model" => "claude-sonnet-4-6",
            "gf.agent.system_prompt_hash" => "e3b0c44298fc1c14",
            "gf.agent.temperature" => 0.7,
            "gf.agent.version" => "v1.0"
          }
        }
      }

      assert %{
               model: "claude-sonnet-4-6",
               system_prompt_hash: "e3b0c44298fc1c14",
               temperature: 0.7,
               version: "v1.0"
             } = Pipeline.extract_agent_config([entry])
    end

    test "extract_agent_config returns nil when no gf.agent.model present" do
      entry = %Ledger{run_id: "x", payload: %{"attributes" => %{"other" => "v"}}}
      assert Pipeline.extract_agent_config([entry]) == nil

      empty_entry = %Ledger{run_id: "y", payload: %{}}
      assert Pipeline.extract_agent_config([empty_entry]) == nil
    end

    test "upsert_agent_configs writes to runs; second call is COALESCE no-op" do
      run_id = fresh_run_id() <> "-cfg"
      Repo.insert!(%Run{run_id: run_id, status: "running"})

      entry = %Ledger{
        run_id: run_id,
        payload: %{
          "attributes" => %{
            "gf.agent.model" => "claude-sonnet-4-6",
            "gf.agent.system_prompt_hash" => "abc123def456abcd",
            "gf.agent.temperature" => 0.7,
            "gf.agent.version" => "v1.0"
          }
        }
      }

      Pipeline.upsert_agent_configs([entry])

      run = Repo.get(Run, run_id)
      assert run.model == "claude-sonnet-4-6"
      assert run.system_prompt_hash == "abc123def456abcd"
      assert run.temperature == 0.7
      assert run.version == "v1.0"

      # Druhý batch s jinými hodnotami → COALESCE first-wins, žádná změna
      entry2 = put_in(entry.payload["attributes"]["gf.agent.model"], "claude-opus-4-7")
      Pipeline.upsert_agent_configs([entry2])

      run_after = Repo.get(Run, run_id)
      assert run_after.model == "claude-sonnet-4-6"
    end
  end
end
