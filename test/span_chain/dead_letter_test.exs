defmodule SpanChain.DeadLetterTest do
  use SpanChain.DataCase, async: false

  alias SpanChain.DeadLetter

  # GF-667: retry behavior + dead-letter emission z SGS odstraněno (test seamy
  # insert_fun + retry_delay_ms zmizely při SGS slim refactoru). Retry logika
  # se přesunula do Pipeline.handle_batch; její dead-letter integrace je
  # pokryta v pipeline_test.exs. Tady ponecháváme jen unit testy
  # SpanChain.DeadLetter public API (store/list/resolve).

  defp fresh_run_id, do: "dl-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  describe "DeadLetter API shape" do
    test "store/3 persists run_id, batch, error_reason, resolved=false" do
      run_id = fresh_run_id()
      batch = [%{seq: 0, event_type: "x", payload: %{"k" => "v"}}]

      {:ok, entry} = DeadLetter.store(run_id, batch, "boom: connection refused")

      assert entry.run_id == run_id
      assert entry.error_reason == "boom: connection refused"
      assert entry.resolved == false
      assert %{"spans" => [%{"seq" => 0, "event_type" => "x"}]} = entry.batch
    end

    test "store/3 stringifies non-binary reasons via inspect" do
      run_id = fresh_run_id()
      {:ok, entry} = DeadLetter.store(run_id, [], {:exit, :killed})
      assert entry.error_reason == "{:exit, :killed}"
    end

    test "list_unresolved/0 returns only entries with resolved=false" do
      run_id_a = fresh_run_id()
      run_id_b = fresh_run_id()

      {:ok, a} = DeadLetter.store(run_id_a, [%{x: 1}], "fail-a")
      {:ok, _b} = DeadLetter.store(run_id_b, [%{x: 2}], "fail-b")

      {:ok, _} = DeadLetter.resolve(a.id)

      unresolved_ids =
        DeadLetter.list_unresolved()
        |> Enum.filter(&(&1.run_id in [run_id_a, run_id_b]))
        |> Enum.map(& &1.run_id)

      assert run_id_b in unresolved_ids
      refute run_id_a in unresolved_ids
    end

    test "resolve/1 returns {:error, :not_found} for unknown id" do
      assert {:error, :not_found} = DeadLetter.resolve(999_999_999)
    end
  end
end
