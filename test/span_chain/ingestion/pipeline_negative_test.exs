defmodule SpanChain.Ingestion.PipelineNegativeTest do
  @moduledoc """
  Negative paths of the Pipeline (GF-648) — tests retry exhaustion, the dead-letter
  fallback, and the defensive layer when the dead-letter itself fails.

  Stubs are swapped via `Application.put_env(:span_chain, :ledger_module, ...)`
  and `:dead_letter_module` in setup; `on_exit` restores the prior values.
  `async: false` guarantees that no parallel test file can read the stub
  instead of the real Ledger.
  """

  use SpanChain.DataCase, async: false

  alias SpanChain.{DeadLetter, Ledger}
  alias SpanChain.Ingestion.{Pipeline, SessionGenServer, SessionSupervisor}

  # ---------------------------------------------------------------------------
  # Inline stubs (CLAUDE.md: no Mox — hand-rolled DI seams)
  # ---------------------------------------------------------------------------

  defmodule LedgerRaisingStub do
    @moduledoc "Always raises — simulates a permanent DB outage (Scenarios A, C)."
    @behaviour SpanChain.Ledger.Behaviour

    def insert_batch(_entries), do: raise("stub_db_down")
  end

  defmodule LedgerEventuallyOkStub do
    @moduledoc """
    The first 2 attempts raise, the 3rd delegates to the real Ledger.insert_batch
    (Scenario B). The counter lives in a dedicated `Agent` process (PID in Application
    env), surviving the `Process.sleep` in Pipeline.with_retry.

    GF-702: previously a global VM-state mechanism with GC overhead — now an Agent
    process per-test, with clean cleanup semantics via `Agent.stop`.
    """
    @behaviour SpanChain.Ledger.Behaviour

    @env_key :ledger_stub_counter

    def setup_counter do
      {:ok, pid} = Agent.start_link(fn -> 0 end)
      Application.put_env(:span_chain, @env_key, pid)
      :ok
    end

    def cleanup_counter do
      case Application.get_env(:span_chain, @env_key) do
        nil ->
          :ok

        pid ->
          if Process.alive?(pid), do: Agent.stop(pid)
          Application.delete_env(:span_chain, @env_key)
          :ok
      end
    end

    def insert_batch(entries) do
      pid = Application.fetch_env!(:span_chain, @env_key)
      n = Agent.get_and_update(pid, fn count -> {count + 1, count + 1} end)

      if n <= 2 do
        raise "stub_db_down_attempt_#{n}"
      else
        Ledger.insert_batch(entries)
      end
    end
  end

  defmodule DeadLetterRaisingStub do
    @moduledoc "DeadLetter.store raises — Scenario C defensive layer."
    def store(_run_id, _batch, _reason), do: raise("stub_dead_letter_down")
  end

  # ---------------------------------------------------------------------------
  # Telemetry helpers — filter on our own run_id (the parallel happy-path tests
  # in `pipeline_test.exs` share the same Pipeline and fire events across it).
  # ---------------------------------------------------------------------------

  defp attach_event(event, run_id) do
    test_pid = self()
    ref = make_ref()
    handler_id = "neg-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      event,
      fn _e, m, meta, _ ->
        if run_id in Map.get(meta, :run_ids, []) do
          send(test_pid, {event, ref, m, meta})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  defp fresh_run_id, do: "neg-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  # ---------------------------------------------------------------------------
  # Setup — per-describe env save / restore
  # ---------------------------------------------------------------------------

  describe "negative path" do
    setup do
      prior_ledger = Application.get_env(:span_chain, :ledger_module)
      prior_dl = Application.get_env(:span_chain, :dead_letter_module)

      on_exit(fn ->
        if prior_ledger,
          do: Application.put_env(:span_chain, :ledger_module, prior_ledger),
          else: Application.delete_env(:span_chain, :ledger_module)

        if prior_dl,
          do: Application.put_env(:span_chain, :dead_letter_module, prior_dl),
          else: Application.delete_env(:span_chain, :dead_letter_module)
      end)

      :ok
    end

    # -------------------------------------------------------------------------
    # Scenario B (test order: first — proves harness + verify_ledger work)
    # 2× failure, 3rd attempt success → no DeadLetter, valid hash chain.
    # -------------------------------------------------------------------------

    test "scenario B — 2 failures + 1 success persists entry, no dead letter" do
      LedgerEventuallyOkStub.setup_counter()
      on_exit(&LedgerEventuallyOkStub.cleanup_counter/0)

      Application.put_env(:span_chain, :ledger_module, LedgerEventuallyOkStub)

      run_id = fresh_run_id()
      ok_ref = attach_event([:gf, :ledger, :batch_insert, :stop], run_id)

      {:ok, sgs_pid} = SessionSupervisor.ensure_session(run_id)
      {:ok, 1} = SessionGenServer.ingest_spans(run_id, [%{"name" => "scenario_b"}])

      assert_receive {[:gf, :ledger, :batch_insert, :stop], ^ok_ref, _m, _meta}, 2_000

      assert Repo.aggregate(from(d in DeadLetter, where: d.run_id == ^run_id), :count, :id) == 0
      assert {:ok, 1} = Ledger.verify_ledger(run_id)
      assert Process.alive?(sgs_pid)
    end

    # -------------------------------------------------------------------------
    # Scenario A — 3× failure → DeadLetter populated, SGS still alive
    # -------------------------------------------------------------------------

    test "scenario A — retry exhaustion routes entry to DeadLetter" do
      Application.put_env(:span_chain, :ledger_module, LedgerRaisingStub)

      run_id = fresh_run_id()
      dl_ref = attach_event([:gf, :flush, :dead_letter], run_id)

      {:ok, sgs_pid} = SessionSupervisor.ensure_session(run_id)
      {:ok, 1} = SessionGenServer.ingest_spans(run_id, [%{"name" => "scenario_a"}])

      assert_receive {[:gf, :flush, :dead_letter], ^dl_ref, %{count: count}, meta}, 2_000
      assert count >= 1
      assert run_id in meta.run_ids

      # We filter dead-letter entries to our run_id — parallel tests may
      # add their own records to the shared DB.
      dead_letters =
        from(d in DeadLetter, where: d.run_id == ^run_id and d.resolved == false)
        |> Repo.all()

      assert length(dead_letters) >= 1
      [dl | _] = dead_letters
      assert dl.error_reason =~ "stub_db_down"
      assert Process.alive?(sgs_pid)
    end

    # -------------------------------------------------------------------------
    # Scenario C — DeadLetter.store itself raises → Pipeline + SGS survive,
    # the telemetry event [:gf, :flush, :dead_letter] still fires.
    # -------------------------------------------------------------------------

    test "scenario C — dead_letter raise does not crash Pipeline or SGS, telemetry still emits" do
      Application.put_env(:span_chain, :ledger_module, LedgerRaisingStub)
      Application.put_env(:span_chain, :dead_letter_module, DeadLetterRaisingStub)

      run_id = fresh_run_id()
      dl_ref = attach_event([:gf, :flush, :dead_letter], run_id)
      pipeline_pid = Process.whereis(Pipeline)

      {:ok, sgs_pid} = SessionSupervisor.ensure_session(run_id)
      {:ok, 1} = SessionGenServer.ingest_spans(run_id, [%{"name" => "scenario_c"}])

      assert_receive {[:gf, :flush, :dead_letter], ^dl_ref, _m, meta}, 2_000
      assert run_id in meta.run_ids

      # Defensive layer: neither the Pipeline (Broadway top supervisor) nor the SGS may
      # crash when the dead-letter store raises.
      assert Process.alive?(sgs_pid)
      assert Process.alive?(pipeline_pid)
      assert Process.whereis(Pipeline) == pipeline_pid

      # The stub only raises → no row in dead_letter_entries for this run.
      assert Repo.aggregate(from(d in DeadLetter, where: d.run_id == ^run_id), :count, :id) == 0
    end

    # -------------------------------------------------------------------------
    # Coverage extras (Done When: ≥5 new tests)
    # -------------------------------------------------------------------------

    test "scenario A — error_reason in DeadLetter includes stub failure message" do
      Application.put_env(:span_chain, :ledger_module, LedgerRaisingStub)

      run_id = fresh_run_id()
      dl_ref = attach_event([:gf, :flush, :dead_letter], run_id)

      {:ok, _sgs_pid} = SessionSupervisor.ensure_session(run_id)
      {:ok, 1} = SessionGenServer.ingest_spans(run_id, [%{"name" => "err_reason_check"}])

      assert_receive {[:gf, :flush, :dead_letter], ^dl_ref, _m, _meta}, 2_000

      [dl] =
        from(d in DeadLetter, where: d.run_id == ^run_id)
        |> Repo.all()

      assert dl.error_reason =~ "stub_db_down"
      assert dl.resolved == false
      assert %{"spans" => [_span]} = dl.batch
    end

    test "scenario C — Pipeline accepts a second batch after store failure" do
      Application.put_env(:span_chain, :ledger_module, LedgerRaisingStub)
      Application.put_env(:span_chain, :dead_letter_module, DeadLetterRaisingStub)

      run_id = fresh_run_id()
      dl_ref = attach_event([:gf, :flush, :dead_letter], run_id)

      {:ok, _sgs_pid} = SessionSupervisor.ensure_session(run_id)
      {:ok, 1} = SessionGenServer.ingest_spans(run_id, [%{"name" => "scenario_c_1"}])
      assert_receive {[:gf, :flush, :dead_letter], ^dl_ref, _m, _meta}, 2_000

      # The second batch after a store failure must go through the same path — the Pipeline must
      # not be in a broken state.
      {:ok, 1} = SessionGenServer.ingest_spans(run_id, [%{"name" => "scenario_c_2"}])
      assert_receive {[:gf, :flush, :dead_letter], ^dl_ref, _m, _meta}, 2_000
    end
  end
end
