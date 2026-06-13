defmodule SpanChain.LedgerVerifierTest do
  @moduledoc """
  GF-788: LedgerVerifier.sweep_now/0 — healthy ledger, chain_broken detection with
  telemetry, and empty window. Calls sweep_now/0 directly; GenServer runs with
  :infinity interval (config/test.exs), so no auto-sweep fires.
  """
  use SpanChain.DataCase, async: false

  import Ecto.Query

  alias SpanChain.Repo
  alias SpanChain.Ledger
  alias SpanChain.LedgerVerifier
  alias SpanChain.Ingestion.SessionSupervisor
  alias SpanChain.Ingestion.SessionGenServer

  setup do
    # Allow the named LedgerVerifier GenServer to use the test's sandbox connection.
    Ecto.Adapters.SQL.Sandbox.allow(
      SpanChain.Repo,
      self(),
      Process.whereis(SpanChain.LedgerVerifier)
    )

    :ok
  end

  defp attach_chain_broken_handler(test_pid) do
    handler_id = "test-chain-broken-#{inspect(test_pid)}"

    :telemetry.attach(
      handler_id,
      [:span_chain, :ledger, :chain_broken],
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp ingest_and_flush(run_id) do
    Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")
    {:ok, _pid} = SessionSupervisor.ensure_session(run_id)
    {:ok, _n} = SessionGenServer.ingest_spans(run_id, [%{"name" => "verifier-test-span"}])
    assert_receive {:spans_flushed, ^run_id}, 5_000
  end

  describe "sweep_now/0" do
    test "sweep across healthy ledger — no broken runs" do
      run_id = "lv-healthy-#{System.unique_integer([:positive])}"
      ingest_and_flush(run_id)

      result = LedgerVerifier.sweep_now()

      assert %{checked: c, broken: 0} = result
      assert c >= 1
    end

    test "sweep detects chain_broken and emits telemetry" do
      run_id = "lv-tamper-#{System.unique_integer([:positive])}"
      ingest_and_flush(run_id)
      attach_chain_broken_handler(self())

      Repo.update_all(
        from(l in Ledger, where: l.run_id == ^run_id),
        set: [hash: "tampered"]
      )

      LedgerVerifier.sweep_now()

      assert_receive {:telemetry, [:span_chain, :ledger, :chain_broken], _measurements,
                      %{run_id: ^run_id}}
    end

    test "empty window — no runs ingested, returns checked: 0, broken: 0" do
      result = LedgerVerifier.sweep_now()

      assert result == %{checked: 0, broken: 0}
      refute_received {:telemetry, [:span_chain, :ledger, :chain_broken], _, _}
    end
  end
end
