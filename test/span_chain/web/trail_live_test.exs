defmodule SpanChain.Web.TrailLiveTest do
  @moduledoc """
  Real-time `/trail` auto-refresh via Phoenix.PubSub (backlog #9 + #10).

  The Pipeline broadcasts after a successful batch insert — the LiveView subscribes
  per route and re-fetches on an incoming message. Tests:
    1. index `/trail` re-fetch on `{:run_updated, _}`
    2. detail `/trail/:run_id` re-fetch on `{:spans_flushed, run_id}`
    3. isolation — detail A doesn't pick up a broadcast for detail B
  """

  use SpanChain.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SpanChain.Ingestion.{SessionGenServer, SessionSupervisor}

  @endpoint SpanChain.Web.Endpoint

  defp fresh_run_id, do: "trail-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  # Reuse the pattern from pipeline_test.exs:16-50 — a telemetry filter on run_ids
  # in the metadata isolates events from parallel happy-path tests.
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
      # iterates subscribers and delivers SYNC into all mailboxes; when the test gets
      # {:run_updated, _}, the LiveView already has the message in its mailbox → a sync render(view)
      # processes handle_info BEFORE it returns state. Without this there's a race: the telemetry
      # [:gf, :ledger, :batch_insert, :stop] fires before the broadcast → the test outruns the
      # LiveView handle_info → render returns the old state.
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

      # Same anti-race trick as the index test — see the comment there.
      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")
      :ok = ingest_one(run_id, "second")
      assert_receive {:spans_flushed, ^run_id}, 2_000

      html2 = render(view)
      assert html2 =~ "2 ledger rows"
    end
  end

  describe "TRAIL_AUTH_ENABLED gate (GF-978)" do
    test "GET /trail with TRAIL_AUTH_ENABLED=true and no credentials returns 401" do
      Application.put_env(:span_chain, :trail_auth_enabled, true)
      on_exit(fn -> Application.put_env(:span_chain, :trail_auth_enabled, false) end)

      conn = build_conn() |> get("/trail")
      assert conn.status == 401
      assert Plug.Conn.get_resp_header(conn, "www-authenticate") != []
    end

    test "GET /trail without TRAIL_AUTH_ENABLED returns 200 (default behavior)" do
      conn = build_conn() |> get("/trail")
      assert conn.status == 200
    end

    test "on_mount with trail_auth_enabled=true and no session halts WebSocket" do
      # WebSocket upgrade bypasses the Plug pipeline — on_mount is the second guard.
      # Test via direct function call: live() can't simulate this path because it
      # goes through the HTTP plug first (which would 401 before LiveView mounts).
      Application.put_env(:span_chain, :trail_auth_enabled, true)
      on_exit(fn -> Application.put_env(:span_chain, :trail_auth_enabled, false) end)

      socket = %Phoenix.LiveView.Socket{}
      assert {:halt, _socket} = SpanChain.Web.TrailAuth.on_mount(:require_auth, %{}, %{}, socket)
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

      # Manual broadcast for a DIFFERENT run_id — A subscribes only to "run:RUN_A"
      # → a message for run B must not reach the A LiveView.
      Phoenix.PubSub.broadcast(
        SpanChain.PubSub,
        "run:#{run_b}",
        {:spans_flushed, run_b}
      )

      # Testing a negative hypothesis — give the LiveView a window to react, in case it
      # incorrectly subscribed to a global topic. There's no telemetry signal for
      # "nothing happened", so a short sleep is a necessary evil.
      Process.sleep(50)

      html_after = render(view)
      refute html_after =~ run_b
      assert html_after == html_before
    end
  end
end
