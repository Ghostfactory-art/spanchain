defmodule SpanChain.Web.EvalLiveTest do
  @moduledoc """
  LiveView testy pro `/eval/:eval_id` — run selection + Comparator diff render
  (GF-707). Žádná Broadway účast (Comparator čte přímo z Ledger), tudíž žádný
  PubSub / telemetry flush wait pattern.
  """

  use SpanChain.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SpanChain.{Eval, Ledger, Repo, Run}

  @endpoint SpanChain.Web.Endpoint

  # ---------------------------------------------------------------------------
  # Fixtures — mirror comparator_test.exs pattern (direct Repo, no Broadway).
  # ---------------------------------------------------------------------------

  defp fresh_eval_id,
    do: "eval-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp fresh_run_id(prefix \\ "ev"),
    do: "#{prefix}-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp insert_eval(eval_id) do
    Repo.insert!(%Eval{eval_id: eval_id, status: "running"})
  end

  defp insert_run(run_id, eval_id \\ nil) do
    Repo.insert!(%Run{run_id: run_id, status: "completed", eval_id: eval_id})
  end

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

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "mount /eval/:eval_id" do
    test "unknown eval_id → :error view with 'Eval not found'" do
      {:ok, _view, html} = live(build_conn(), "/eval/does-not-exist-xyz")
      assert html =~ "Eval not found"
      assert html =~ "Eval error"
    end

    test "eval with two runs and no compare params → :select view with both run ids" do
      eval_id = fresh_eval_id()
      insert_eval(eval_id)
      run_a = fresh_run_id()
      run_b = fresh_run_id()
      insert_run(run_a, eval_id)
      insert_run(run_b, eval_id)

      {:ok, _view, html} = live(build_conn(), "/eval/#{eval_id}")

      assert html =~ eval_id
      assert html =~ "2 runs in this eval"
      assert html =~ run_a
      assert html =~ run_b
      assert html =~ ~s(name="run_a")
      assert html =~ ~s(name="run_b")
    end
  end

  describe "diff view /eval/:eval_id?run_a=...&run_b=..." do
    test "duration_diff present → diff table with deviation marker" do
      eval_id = fresh_eval_id()
      insert_eval(eval_id)
      run_a = fresh_run_id("a")
      run_b = fresh_run_id("b")
      insert_run(run_a, eval_id)
      insert_run(run_b, eval_id)

      insert_root_with_child(run_a, "agent_run", "llm_call", duration_ms: 100)
      insert_root_with_child(run_b, "agent_run", "llm_call", duration_ms: 500)

      {:ok, _view, html} = live(build_conn(), "/eval/#{eval_id}?run_a=#{run_a}&run_b=#{run_b}")

      assert html =~ run_a
      assert html =~ run_b
      assert html =~ "llm_call"
      assert html =~ "duration_diff"
      assert html =~ "100ms"
      assert html =~ "500ms"
      # mark_deviation_points/1 marks the first diff entry — must surface as ⚠
      assert html =~ "⚠"
      # diff_pct = round(abs(500-100)/100 * 100) = 400
      assert html =~ "400%"
    end

    test "identical runs → 'Identical runs' message and no diff table" do
      eval_id = fresh_eval_id()
      insert_eval(eval_id)
      run_a = fresh_run_id("a")
      run_b = fresh_run_id("b")
      insert_run(run_a, eval_id)
      insert_run(run_b, eval_id)

      insert_root_with_child(run_a, "agent_run", "llm_call", duration_ms: 100)
      insert_root_with_child(run_b, "agent_run", "llm_call", duration_ms: 100)

      {:ok, _view, html} = live(build_conn(), "/eval/#{eval_id}?run_a=#{run_a}&run_b=#{run_b}")

      assert html =~ "Identical runs"
      refute html =~ "duration_diff"
    end

    test "runs from different evals → :error view with 'different evals' wording" do
      eval_a_id = fresh_eval_id()
      eval_b_id = fresh_eval_id()
      insert_eval(eval_a_id)
      insert_eval(eval_b_id)

      run_a = fresh_run_id("a")
      run_b = fresh_run_id("b")
      insert_run(run_a, eval_a_id)
      insert_run(run_b, eval_b_id)

      {:ok, _view, html} =
        live(build_conn(), "/eval/#{eval_a_id}?run_a=#{run_a}&run_b=#{run_b}")

      assert html =~ "different evals"
      assert html =~ "Eval error"
    end
  end

  describe "handle_event/3 compare" do
    test "submitting form with both runs push_patches to diff URL" do
      eval_id = fresh_eval_id()
      insert_eval(eval_id)
      run_a = fresh_run_id("a")
      run_b = fresh_run_id("b")
      insert_run(run_a, eval_id)
      insert_run(run_b, eval_id)

      insert_root_with_child(run_a, "agent_run", "llm_call", duration_ms: 100)
      insert_root_with_child(run_b, "agent_run", "llm_call", duration_ms: 100)

      {:ok, view, _html} = live(build_conn(), "/eval/#{eval_id}")

      html =
        view
        |> form("form", %{"run_a" => run_a, "run_b" => run_b})
        |> render_submit()

      # After push_patch, render returns the diff view body
      assert html =~ run_a
      assert html =~ run_b
      assert html =~ "Identical runs"
    end
  end
end
