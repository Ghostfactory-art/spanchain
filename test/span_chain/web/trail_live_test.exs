defmodule SpanChain.Web.TrailLiveTest do
  @moduledoc """
  Real-time `/trail` auto-refresh přes Phoenix.PubSub (backlog #9 + #10).

  Pipeline broadcastuje po úspěšném batch insertu — LiveView subscribuje
  per route a re-fetchuje na příchozí zprávu. Testuje:
    1. index `/trail` re-fetch na `{:run_updated, _}`
    2. detail `/trail/:run_id` re-fetch na `{:spans_flushed, run_id}`
    3. isolation — detail A neagreguje broadcast pro detail B
  """

  use SpanChain.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SpanChain.Ingestion.{SessionGenServer, SessionSupervisor}

  @endpoint SpanChain.Web.Endpoint

  defp fresh_run_id, do: "trail-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  # Reuse pattern z pipeline_test.exs:16-50 — telemetry filter na run_ids
  # v metadata izoluje events od paralelních happy-path testů.
  defp attach_flush_handler(run_id) do
    test_pid = self()
    ref = make_ref()
    handler_id = "trail-flush-#{inspect(ref)}"

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

  defp ingest_one(run_id, name) do
    {:ok, _pid} = SessionSupervisor.ensure_session(run_id)
    {:ok, _n} = SessionGenServer.ingest_spans(run_id, [%{"name" => name}])
    :ok
  end

  describe "index `/trail`" do
    test "auto-refresh — new run_id appears after Pipeline broadcast" do
      {:ok, view, _html} = live(build_conn(), "/trail")

      run_id = fresh_run_id()
      # Subscribe test process to "runs" same as LiveView. Phoenix.PubSub.broadcast
      # iteruje subscribery a doručuje SYNC do všech mailboxů; když test dostane
      # {:run_updated, _}, LiveView má zprávu už ve své mailbox → sync render(view)
      # zpracuje handle_info DŘÍVE než vrátí state. Bez tohoto je race: telemetry
      # [:gf, :ledger, :batch_insert, :stop] fire dřív než broadcast → test předběhne
      # LiveView handle_info → render vrátí starý state.
      Phoenix.PubSub.subscribe(SpanChain.PubSub, "runs")

      :ok = ingest_one(run_id, "auto_refresh_index")
      assert_receive {:run_updated, ^run_id}, 2_000

      html = render(view)
      assert html =~ run_id
    end
  end

  describe "detail `/trail/:run_id`" do
    test "auto-refresh — row count grows after second batch" do
      run_id = fresh_run_id()
      ref = attach_flush_handler(run_id)
      :ok = ingest_one(run_id, "first")
      assert_receive {:flushed, ^ref, _}, 2_000

      {:ok, view, html} = live(build_conn(), "/trail/#{run_id}")
      assert html =~ "1 ledger rows"

      # Stejný anti-race trik jako index test — viz komentář tam.
      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")
      :ok = ingest_one(run_id, "second")
      assert_receive {:spans_flushed, ^run_id}, 2_000

      html2 = render(view)
      assert html2 =~ "2 ledger rows"
    end
  end

  describe "subscribe isolation" do
    test "detail A unchanged after manual broadcast for run B" do
      run_a = fresh_run_id()
      run_b = fresh_run_id()

      ref_a = attach_flush_handler(run_a)
      :ok = ingest_one(run_a, "a_init")
      assert_receive {:flushed, ^ref_a, _}, 2_000

      {:ok, view, _initial_html} = live(build_conn(), "/trail/#{run_a}")
      html_before = render(view)

      # Manuální broadcast pro JINÝ run_id — A subscribuje pouze na "run:RUN_A"
      # → message pro run B nesmí dorazit do A LiveView.
      Phoenix.PubSub.broadcast(
        SpanChain.PubSub,
        "run:#{run_b}",
        {:spans_flushed, run_b}
      )

      # Test negativní hypotézy — dáme LiveView okno reagovat, kdyby chybně
      # subscriboval na global topic. Žádný telemetry signál neexistuje pro
      # "nic se nestalo", takže krátký sleep je nutné zlo.
      Process.sleep(50)

      html_after = render(view)
      refute html_after =~ run_b
      assert html_after == html_before
    end
  end
end
