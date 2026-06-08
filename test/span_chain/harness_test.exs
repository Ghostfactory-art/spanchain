defmodule SpanChain.HarnessTest do
  use SpanChain.DataCase, async: false

  alias SpanChain.Harness
  alias SpanChain.Ingestion.SessionSupervisor
  alias SpanChain.Ledger

  defp fresh_run_id, do: "harness-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp start_harness do
    run_id = fresh_run_id()
    {:ok, harness} = Harness.start_link(run_id: run_id)
    {:ok, session_pid} = SessionSupervisor.ensure_session(run_id)
    Ecto.Adapters.SQL.Sandbox.allow(SpanChain.Repo, self(), session_pid)
    ref = attach_flush_handler(self())
    {run_id, harness, session_pid, ref}
  end

  # GF-667: flush_now/1 no longer exists (Broadway async flush). Instead we
  # attach the telemetry handler [:gf, :ledger, :batch_insert, :stop] before the
  # action and wait for the cumulative count via wait_for_flushed_count/3.
  defp attach_flush_handler(test_pid) do
    ref = make_ref()
    handler_id = "harness-flush-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      [:gf, :ledger, :batch_insert, :stop],
      fn _e, %{count: count}, _md, _ -> send(test_pid, {:flushed_count, ref, count}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  defp wait_for_flushed_count(ref, expected, timeout_ms \\ 5_000) do
    do_wait(ref, 0, expected, timeout_ms)
  end

  defp do_wait(_ref, acc, expected, _t) when acc >= expected, do: :ok

  defp do_wait(ref, acc, expected, timeout_ms) do
    receive do
      {:flushed_count, ^ref, count} -> do_wait(ref, acc + count, expected, timeout_ms)
    after
      timeout_ms -> {:error, {:timeout, acc, expected}}
    end
  end

  defp rows_for(run_id) do
    from(l in Ledger, where: l.run_id == ^run_id, order_by: [asc: l.seq])
    |> Repo.all()
  end

  test "start_span + end_span: the span is stored in the Ledger with the correct values" do
    {run_id, harness, _, ref} = start_harness()

    {:ok, span_id} = Harness.start_span(harness, "llm_call", %{model: "claude-sonnet"})
    :ok = Harness.end_span(harness, span_id, %{status: :ok, tokens: 312})

    :ok = wait_for_flushed_count(ref, 1)
    Harness.stop(harness)

    [row] = rows_for(run_id)
    assert row.event_type == "llm_call"
    assert row.parent_span_id == nil

    attrs = row.payload["attributes"]
    assert attrs["model"] == "claude-sonnet"
    assert attrs["status"] == "ok"
    assert attrs["tokens"] == 312
    assert row.payload["span_id"] == span_id
    assert is_integer(row.payload["duration_ms"])
  end

  test "with_span with a successful function: span stored, result returned transparently" do
    {run_id, harness, _, ref} = start_harness()

    result = Harness.with_span(harness, "agent_run", %{task: "hello"}, fn -> "world" end)
    assert result == "world"

    :ok = wait_for_flushed_count(ref, 1)
    Harness.stop(harness)

    [row] = rows_for(run_id)
    assert row.event_type == "agent_run"
    attrs = row.payload["attributes"]
    assert attrs["task"] == "hello"
    assert attrs["status"] == "ok"
    assert attrs["result"] == "\"world\""
  end

  test "with_span with an exception: span stored as :error, the exception is reraised" do
    {run_id, harness, _, ref} = start_harness()

    assert_raise RuntimeError, "boom", fn ->
      Harness.with_span(harness, "broken_step", %{}, fn -> raise "boom" end)
    end

    :ok = wait_for_flushed_count(ref, 1)
    Harness.stop(harness)

    [row] = rows_for(run_id)
    assert row.event_type == "broken_step"
    attrs = row.payload["attributes"]
    assert attrs["status"] == "error"
    assert attrs["error"] =~ "boom"
  end

  test "nested spans: parent_span_id linked exactly via the explicit argument" do
    {run_id, harness, _, ref} = start_harness()

    {:ok, parent_id} = Harness.start_span(harness, "agent_run", %{})

    {:ok, child_id} =
      Harness.start_span(harness, "tool_call", %{tool: "search"}, parent_span_id: parent_id)

    :ok = Harness.end_span(harness, child_id, %{status: :ok})
    :ok = Harness.end_span(harness, parent_id, %{status: :ok})

    :ok = wait_for_flushed_count(ref, 2)
    Harness.stop(harness)

    rows = rows_for(run_id)
    assert length(rows) == 2

    child_row = Enum.find(rows, &(&1.event_type == "tool_call"))
    parent_row = Enum.find(rows, &(&1.event_type == "agent_run"))

    assert child_row.parent_span_id == parent_id
    assert parent_row.parent_span_id == nil
    assert child_row.payload["span_id"] == child_id
    assert parent_row.payload["span_id"] == parent_id
  end

  test "stop/1: unfinished spans are persisted as :abandoned" do
    {run_id, harness, _, ref} = start_harness()

    {:ok, closed_id} = Harness.start_span(harness, "ended_step", %{})
    :ok = Harness.end_span(harness, closed_id, %{status: :ok})

    {:ok, _stuck_id} = Harness.start_span(harness, "stuck_step", %{trace: "abc"})
    {:ok, _stuck2} = Harness.start_span(harness, "another_stuck", %{})

    Harness.stop(harness)
    :ok = wait_for_flushed_count(ref, 3)

    rows = rows_for(run_id)
    assert length(rows) == 3

    stuck = Enum.find(rows, &(&1.event_type == "stuck_step"))
    assert stuck.payload["attributes"]["status"] == "abandoned"
    assert stuck.payload["attributes"]["trace"] == "abc"

    another = Enum.find(rows, &(&1.event_type == "another_stuck"))
    assert another.payload["attributes"]["status"] == "abandoned"

    ended = Enum.find(rows, &(&1.event_type == "ended_step"))
    assert ended.payload["attributes"]["status"] == "ok"
  end
end
