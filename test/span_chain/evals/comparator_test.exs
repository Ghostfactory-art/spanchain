defmodule SpanChain.Evals.ComparatorTest do
  @moduledoc """
  Pure tree diff tests pro Evals.Comparator (GF-706). Insert spans přes
  `Ledger.insert_batch/1` (žádný Pipeline, deterministic), Run/Eval rows
  insertujeme přímo. async: false (DataCase shared sandbox).
  """

  use SpanChain.DataCase, async: false

  alias SpanChain.{Eval, Ledger, Repo, Run}
  alias SpanChain.Evals.Comparator

  defp fresh_run_id(prefix \\ "cmp"),
    do: "#{prefix}-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp insert_run(run_id, eval_id \\ nil) do
    %Run{run_id: run_id, status: "completed", eval_id: eval_id}
    |> Repo.insert!()
  end

  # GF-748: Run with gf.agent.* projection fields
  defp insert_run_with_config(run_id, opts) do
    %Run{
      run_id: run_id,
      status: "completed",
      model: opts[:model],
      system_prompt_hash: opts[:system_prompt_hash],
      temperature: opts[:temperature],
      version: opts[:version]
    }
    |> Repo.insert!()
  end

  defp insert_eval(eval_id) do
    %Eval{eval_id: eval_id, status: "running"}
    |> Repo.insert!()
  end

  # Vytvoří span s ms-precision started_at/ended_at v payloadu pro reliable
  # duration_ms výpočet (projekční sloupce mají second precision → loss při
  # sub-second testech).
  defp span_entry(run_id, seq, event_type, opts \\ []) do
    duration_ms = Keyword.get(opts, :duration_ms, 100)
    parent_span_id = Keyword.get(opts, :parent_span_id)
    span_id = Keyword.get(opts, :span_id, "s-#{seq}-#{:rand.uniform(10_000)}")
    base = ~U[2026-05-17 12:00:00.000Z]
    started = base
    ended = DateTime.add(base, duration_ms, :millisecond)

    payload = %{
      "span_id" => span_id,
      "started_at" => DateTime.to_iso8601(started),
      "ended_at" => DateTime.to_iso8601(ended)
    }

    Ledger.build_entry(run_id, 0, seq, prev_for_seq(seq), event_type, payload, parent_span_id)
  end

  defp prev_for_seq(0), do: nil
  defp prev_for_seq(_), do: "prev-stub"

  # Helper: stejný tvar tree pro oba runy. Vrací mapu name → span_id pro
  # parent linking.
  defp insert_root_with_child(run_id, root_name, child_name, child_opts \\ []) do
    root_id = "root-#{run_id}"
    child_id = "child-#{run_id}"
    root = span_entry(run_id, 0, root_name, span_id: root_id)

    child =
      span_entry(
        run_id,
        1,
        child_name,
        [parent_span_id: root_id, span_id: child_id] ++ child_opts
      )

    Ledger.insert_batch([root, child])
    %{root: root_id, child: child_id}
  end

  describe "compare/2" do
    test "span_added — B has extra grandchild not in A" do
      run_a = fresh_run_id("a")
      run_b = fresh_run_id("b")
      insert_run(run_a)
      insert_run(run_b)

      ids_a = insert_root_with_child(run_a, "agent_run", "llm_call")
      ids_b = insert_root_with_child(run_b, "agent_run", "llm_call")

      # B má grandchild "tool_call" pod "llm_call"
      grandchild =
        span_entry(run_b, 2, "tool_call",
          parent_span_id: ids_b.child,
          span_id: "gc-#{run_b}"
        )

      Ledger.insert_batch([grandchild])

      _ = ids_a

      assert {:ok, %{"differences" => diffs}} = Comparator.compare(run_a, run_b)

      assert Enum.any?(diffs, fn d ->
               d["type"] == "span_added" and d["span_name"] == "tool_call"
             end)
    end

    test "span_removed — A has child that B does not" do
      run_a = fresh_run_id("a")
      run_b = fresh_run_id("b")
      insert_run(run_a)
      insert_run(run_b)

      # A má root + child, B má jen root
      root_a_id = "root-#{run_a}"
      root_a = span_entry(run_a, 0, "agent_run", span_id: root_a_id)
      child_a = span_entry(run_a, 1, "llm_call", parent_span_id: root_a_id)
      Ledger.insert_batch([root_a, child_a])

      root_b = span_entry(run_b, 0, "agent_run", span_id: "root-#{run_b}")
      Ledger.insert_batch([root_b])

      assert {:ok, %{"differences" => diffs}} = Comparator.compare(run_a, run_b)

      assert Enum.any?(diffs, fn d ->
               d["type"] == "span_removed" and d["span_name"] == "llm_call"
             end)
    end

    test "duration_diff — child >20% slower in B emits diff + deviation_point" do
      run_a = fresh_run_id("a")
      run_b = fresh_run_id("b")
      insert_run(run_a)
      insert_run(run_b)

      insert_root_with_child(run_a, "agent_run", "llm_call", duration_ms: 100)
      insert_root_with_child(run_b, "agent_run", "llm_call", duration_ms: 500)

      assert {:ok, %{"differences" => diffs}} = Comparator.compare(run_a, run_b)
      [first | _] = diffs

      assert first["type"] == "duration_diff"
      assert first["span_name"] == "llm_call"
      assert first["run_a_ms"] == 100
      assert first["run_b_ms"] == 500
      assert first["deviation_point"] == true
    end

    test "different_eval — both runs have non-nil eval_id but differ → error" do
      eval_a = "eval-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      eval_b = "eval-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      insert_eval(eval_a)
      insert_eval(eval_b)

      run_a = fresh_run_id("a")
      run_b = fresh_run_id("b")
      insert_run(run_a, eval_a)
      insert_run(run_b, eval_b)

      assert {:error, :different_eval} = Comparator.compare(run_a, run_b)
    end

    test "run_not_found — missing run → error" do
      assert {:error, :run_not_found} = Comparator.compare("does-not-exist-a", "does-not-exist-b")
    end

    # GF-740: previously `mark_deviation_points/1` označoval pouze index 0
    # plochého diff listu — pokud agent měl 3 souběžné top-level větve a 2 z nich
    # divergovaly, EvalLive ukázal marker jen u první větve. Po opravě každá
    # top-level větev má vlastní first-diff marker.
    test "GF-740: deviation_point per top-level branch, not global index 0" do
      run_a = fresh_run_id("a")
      run_b = fresh_run_id("b")
      insert_run(run_a)
      insert_run(run_b)

      # 3 top-level kořeny (parent_span_id=nil) `branch_a`/`branch_b`/`branch_c`,
      # každý má 1 list (`leaf_a`/`leaf_b`/`leaf_c`). V runu B `leaf_a` a `leaf_c`
      # mají 5× delší duration → 2 duration_diff entries, každý v jiné top-level
      # větvi → 2 deviation_points. `leaf_b` identický → branch_b žádný diff.
      build = fn run_id, da, db, dc ->
        [
          span_entry(run_id, 0, "branch_a", span_id: "br-a-#{run_id}"),
          span_entry(run_id, 1, "leaf_a", parent_span_id: "br-a-#{run_id}", duration_ms: da),
          span_entry(run_id, 2, "branch_b", span_id: "br-b-#{run_id}"),
          span_entry(run_id, 3, "leaf_b", parent_span_id: "br-b-#{run_id}", duration_ms: db),
          span_entry(run_id, 4, "branch_c", span_id: "br-c-#{run_id}"),
          span_entry(run_id, 5, "leaf_c", parent_span_id: "br-c-#{run_id}", duration_ms: dc)
        ]
        |> Ledger.insert_batch()
      end

      build.(run_a, 100, 100, 100)
      build.(run_b, 500, 100, 500)

      assert {:ok, %{"differences" => diffs}} = Comparator.compare(run_a, run_b)

      duration_diffs = Enum.filter(diffs, &(&1["type"] == "duration_diff"))
      assert length(duration_diffs) == 2

      deviations = Enum.filter(diffs, &(&1["deviation_point"] == true))
      assert length(deviations) == 2

      assert deviations |> Enum.map(& &1["span_name"]) |> Enum.sort() ==
               ["leaf_a", "leaf_c"]

      # `leaf_b` v branch_b je identický → branch_b nevygeneruje žádný diff entry
      refute Enum.any?(diffs, &(&1["span_name"] == "leaf_b"))
    end

    test "GF-740: single branch with single deviation → 1 deviation_point (regression)" do
      run_a = fresh_run_id("a")
      run_b = fresh_run_id("b")
      insert_run(run_a)
      insert_run(run_b)

      insert_root_with_child(run_a, "agent_run", "llm_call", duration_ms: 100)
      insert_root_with_child(run_b, "agent_run", "llm_call", duration_ms: 500)

      assert {:ok, %{"differences" => diffs}} = Comparator.compare(run_a, run_b)

      assert Enum.count(diffs, &(&1["deviation_point"] == true)) == 1
      [first | _] = diffs
      assert first["deviation_point"] == true
      assert first["span_name"] == "llm_call"
    end

    test "GF-740: identical runs → empty diff, mark_deviation_points([]) no-op" do
      run_a = fresh_run_id("a")
      run_b = fresh_run_id("b")
      insert_run(run_a)
      insert_run(run_b)

      insert_root_with_child(run_a, "agent_run", "llm_call", duration_ms: 100)
      insert_root_with_child(run_b, "agent_run", "llm_call", duration_ms: 100)

      assert {:ok, %{"differences" => diffs}} = Comparator.compare(run_a, run_b)
      assert diffs == []
    end
  end

  describe "diff_agent_config (GF-748)" do
    test "compare/2: same agent config → no config_diff entries" do
      run_a = fresh_run_id("ca")
      run_b = fresh_run_id("cb")
      insert_run_with_config(run_a, model: "claude-sonnet-4-6", temperature: 0.7)
      insert_run_with_config(run_b, model: "claude-sonnet-4-6", temperature: 0.7)
      insert_root_with_child(run_a, "agent_run", "llm_call")
      insert_root_with_child(run_b, "agent_run", "llm_call")

      assert {:ok, %{"differences" => diffs}} = Comparator.compare(run_a, run_b)
      refute Enum.any?(diffs, &(&1["type"] == "config_diff"))
    end

    test "compare/2: different model → config_diff first in differences" do
      run_a = fresh_run_id("ca")
      run_b = fresh_run_id("cb")
      insert_run_with_config(run_a, model: "claude-sonnet-4-6")
      insert_run_with_config(run_b, model: "claude-opus-4-7")
      insert_root_with_child(run_a, "agent_run", "llm_call")
      insert_root_with_child(run_b, "agent_run", "llm_call")

      assert {:ok, %{"differences" => [first | _]}} = Comparator.compare(run_a, run_b)
      assert first["type"] == "config_diff"
      assert first["field"] == "model"
      assert first["val_a"] == "claude-sonnet-4-6"
      assert first["val_b"] == "claude-opus-4-7"
      refute first["deviation_point"]
    end

    test "compare/2: multiple field diffs returns one config_diff per differing field" do
      run_a = fresh_run_id("ca")
      run_b = fresh_run_id("cb")
      insert_run_with_config(run_a, model: "a", temperature: 0.7, version: "v1")
      insert_run_with_config(run_b, model: "b", temperature: 0.5, version: "v1")
      insert_root_with_child(run_a, "agent_run", "llm_call")
      insert_root_with_child(run_b, "agent_run", "llm_call")

      assert {:ok, %{"differences" => diffs}} = Comparator.compare(run_a, run_b)

      config_fields =
        diffs
        |> Enum.filter(&(&1["type"] == "config_diff"))
        |> Enum.map(& &1["field"])
        |> Enum.sort()

      assert config_fields == ["model", "temperature"]
    end
  end
end
