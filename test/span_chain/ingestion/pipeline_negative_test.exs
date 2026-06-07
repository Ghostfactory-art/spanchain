defmodule SpanChain.Ingestion.PipelineNegativeTest do
  @moduledoc """
  Negativní cesty Pipeline (GF-648) — testuje retry vyčerpání, dead-letter
  fallback, a defenzivní vrstvu když dead-letter sám selže.

  Stubs swap přes `Application.put_env(:span_chain, :ledger_module, ...)`
  a `:dead_letter_module` v setup; `on_exit` restoruje prior hodnoty.
  `async: false` zaručí, že žádný paralelní test soubor nemůže číst stub
  místo reálného Ledgeru.
  """

  use SpanChain.DataCase, async: false

  alias SpanChain.{DeadLetter, Ledger}
  alias SpanChain.Ingestion.{Pipeline, SessionGenServer, SessionSupervisor}

  # ---------------------------------------------------------------------------
  # Inline stubs (CLAUDE.md: žádný Mox — hand-rolled DI seams)
  # ---------------------------------------------------------------------------

  defmodule LedgerRaisingStub do
    @moduledoc "Vždy raise — simuluje trvalý DB výpadek (Scenarios A, C)."
    @behaviour SpanChain.Ledger.Behaviour

    def insert_batch(_entries), do: raise("stub_db_down")
  end

  defmodule LedgerEventuallyOkStub do
    @moduledoc """
    První 2 pokusy raise, 3. delegate na reálný Ledger.insert_batch
    (Scenario B). Counter v dedikovaném `Agent` procesu (PID v Application
    env), survives `Process.sleep` v Pipeline.with_retry.

    GF-702: dřív globální VM-state mechanismus s GC overhead — nyní Agent
    process per-test, čistá cleanup sémantika přes `Agent.stop`.
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
    @moduledoc "DeadLetter.store raise — Scenario C defenzivní vrstva."
    def store(_run_id, _batch, _reason), do: raise("stub_dead_letter_down")
  end

  # ---------------------------------------------------------------------------
  # Telemetry helpers — filtrace na vlastní run_id (paralelní happy-path testy
  # v `pipeline_test.exs` sdílí stejnou Pipeline a fire-uj události napříč).
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
    # 2× failure, 3. attempt success → žádný DeadLetter, valid hash chain.
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

      # Filtrujeme dead-letter entries na náš run_id — paralelní tests mohou
      # přidat své vlastní záznamy do shared DB.
      dead_letters =
        from(d in DeadLetter, where: d.run_id == ^run_id and d.resolved == false)
        |> Repo.all()

      assert length(dead_letters) >= 1
      [dl | _] = dead_letters
      assert dl.error_reason =~ "stub_db_down"
      assert Process.alive?(sgs_pid)
    end

    # -------------------------------------------------------------------------
    # Scenario C — DeadLetter.store sám raise → Pipeline + SGS přežijí,
    # telemetry event [:gf, :flush, :dead_letter] stále fire.
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

      # Defenzivní vrstva: ani Pipeline (Broadway top supervisor) ani SGS nesmí
      # crashnout když dead-letter store raise.
      assert Process.alive?(sgs_pid)
      assert Process.alive?(pipeline_pid)
      assert Process.whereis(Pipeline) == pipeline_pid

      # Stub jen raise → žádný řádek v dead_letter_entries pro tento run.
      assert Repo.aggregate(from(d in DeadLetter, where: d.run_id == ^run_id), :count, :id) == 0
    end

    # -------------------------------------------------------------------------
    # Coverage extras (Done When: ≥5 nových testů)
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

      # Druhý batch po store failure musí projít stejnou cestou — Pipeline nesmí
      # být ve vadném stavu.
      {:ok, 1} = SessionGenServer.ingest_spans(run_id, [%{"name" => "scenario_c_2"}])
      assert_receive {[:gf, :flush, :dead_letter], ^dl_ref, _m, _meta}, 2_000
    end
  end
end
