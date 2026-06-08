defmodule SpanChain.Ingestion.PipelineTest do
  use SpanChain.DataCase, async: false

  alias SpanChain.Ingestion.BufferProducer
  alias SpanChain.Ledger

  # Pipeline + BufferProducer run in the Application supervision tree in the test env
  # (per config/test.exs: start_broadway_pipeline: true, producer_module: BufferProducer).
  # DataCase attaches a telemetry handler for Sandbox.allow on the Broadway processors.

  defp fresh_run_id, do: "pipe-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  # Pipeline + BufferProducer are singletons in the Application supervisor — tests
  # share the pipeline → the handler receives events from all parallel tests.
  # Filtering on a specific `run_id` via `run_ids` in the metadata isolates the events.
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

  test "BufferProducer.enqueue → Pipeline.handle_batch → row in DB (happy path)" do
    run_id = fresh_run_id()
    ref = attach_flush_handler(run_id)

    entry = Ledger.build_entry(run_id, 0, 0, nil, "span", %{"x" => 1}, nil)
    :ok = BufferProducer.enqueue([entry])

    # A shared Pipeline + parallel test files = a batch may contain entries from multiple
    # run_ids → the count in measurements reflects the whole batch, not just ours. The filter
    # handler fires when our run_id is in the batch, then we verify the DB.
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
    # status is a projection created in build_entry AFTER compute_hash (hash unchanged).
    assert entry.status == "error"

    :ok = BufferProducer.enqueue([entry])
    assert_receive {:flushed, ^ref, _measurements}, 2_000

    row = Repo.get_by(Ledger, run_id: run_id, epoch_id: 0, seq: 0)
    assert row.status == "error"
  end

  test "ordering — 5 entries for the same run_id in seq order after a DB roundtrip" do
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
    # The hash chain is valid after the DB roundtrip — verify_ledger checks continuity
    assert {:ok, 5} = Ledger.verify_ledger(run_id)
  end

  test "batch flush — 50 spans go through the pipeline + are in the DB" do
    run_id = fresh_run_id()
    ref = attach_flush_handler(run_id)

    {entries, _} =
      Enum.reduce(0..49, {[], nil}, fn i, {acc, prev_hash} ->
        entry = Ledger.build_entry(run_id, 0, i, prev_hash, "e#{i}", %{}, nil)
        {acc ++ [entry], entry.hash}
      end)

    :ok = BufferProducer.enqueue(entries)
    # Wait until the cumulative inserts for our run_id ≥ 50 (it may be more than one batch)
    :ok = wait_for_run_count(ref, run_id, 50, 5_000)

    assert Repo.aggregate(from(l in Ledger, where: l.run_id == ^run_id), :count, :id) == 50
  end

  # Poll the Repo instead of deriving the count from events (cleanest).
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
        # Process.sleep is OK in integration tests that wait for external async work
        # (Broadway batch_timeout) — the alternative would be a cumulative receive loop, but
        # a batch contains entries from multiple tests → the count is not deterministic.
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
      # GF-790: started_at is the oldest span started_at from the batch, not the insert time.
      assert DateTime.compare(run.started_at, ~U[2026-05-15 10:00:00Z]) == :eq
    end

    test "ensure_run_records preserves existing run status on conflict (GF-790: only started_at upserted)" do
      run_id = fresh_run_id() <> "-idem-run"
      Repo.insert!(%Run{run_id: run_id, status: "completed"})

      # GF-790: on_conflict updates ONLY started_at (LEAST) → the status "completed"
      # stays untouched. The second call must not throw.
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

      # Batch 2: older 10:00:01 → LEAST picks the older value
      assert Pipeline.ensure_run_records([
               entry_with(run_id, payload: %{"started_at" => "2026-05-15T10:00:01Z"})
             ]) == :ok

      assert DateTime.compare(Repo.get(Run, run_id).started_at, ~U[2026-05-15 10:00:01Z]) == :eq

      # Batch 3: newer 10:00:09 → LEAST keeps the existing older value
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

      # The second batch with a different eval_id → an Eval row for `second` is created, but
      # runs.eval_id stays `first` (COALESCE).
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

      # The Ledger entry must be inserted WITHOUT the :eval_id column (schema fields only).
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

      # The second batch with different values → COALESCE first-wins, no change
      entry2 = put_in(entry.payload["attributes"]["gf.agent.model"], "claude-opus-4-7")
      Pipeline.upsert_agent_configs([entry2])

      run_after = Repo.get(Run, run_id)
      assert run_after.model == "claude-sonnet-4-6"
    end
  end
end
