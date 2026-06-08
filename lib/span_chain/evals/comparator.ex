defmodule SpanChain.Evals.Comparator do
  @moduledoc """
  Structural diff of two runs (GF-706). Pure logic — no GenServer, no state.
  Repo.all as the only side effect (deterministic for a given DB snapshot).

  ## Diff semantics

  Span trees are built from the `parent_span_id` hierarchy (`build_tree/1` —
  algorithm copied from `TrailLive.build_tree`). Children are paired by
  `name` + sibling position:

  * nodes in B with no match in A → `"span_added"`
  * nodes in A with no match in B → `"span_removed"`
  * paired nodes with a >20% difference in `duration_ms` → `"duration_diff"`
    with concrete `run_a_ms` / `run_b_ms` values
  * an agent config field (`model` / `system_prompt_hash` / `temperature` /
    `version`) differing between runs → `"config_diff"` with `field` / `val_a` / `val_b`
    (GF-748, projection from `gf.agent.*` span attrs). Config diffs are
    prepended BEFORE the span tree diffs as root-cause context.

  The first emitted diff in each root branch gets `"deviation_point" => true`
  (a signal "this is where behavior first diverged"). Config diffs do NOT get the marker
  — they are pre-flight context, not a deviation in the span tree.

  If both runs have a non-nil `eval_id` and they differ → `{:error, :different_eval}`
  (it makes no sense to compare runs from different evals).
  """

  import Ecto.Query

  alias SpanChain.{Ledger, Repo, Run}

  @duration_threshold 0.20

  @spec compare(String.t(), String.t()) ::
          {:ok, map()} | {:error, :run_not_found | :different_eval}
  def compare(run_id_a, run_id_b) when is_binary(run_id_a) and is_binary(run_id_b) do
    with {:ok, %{run: run_a, tree: tree_a, spans: spans_a}} <- load_run(run_id_a),
         {:ok, %{run: run_b, tree: tree_b, spans: spans_b}} <- load_run(run_id_b),
         :ok <- check_same_eval(run_a, run_b) do
      summary = %{
        "eval_id" => run_a.eval_id || run_b.eval_id,
        "run_a" => summarize(spans_a),
        "run_b" => summarize(spans_b)
      }

      # GF-748: config diffs FIRST (root-cause context before the span tree divergence).
      # mark_deviation_points operates inside diff_trees per top-level branch,
      # so config_diffs don't get the marker; the span tree keeps the existing semantics.
      config_diffs = diff_agent_config(run_a, run_b)
      tree_diffs = diff_trees(tree_a, tree_b)
      differences = config_diffs ++ tree_diffs

      {:ok, %{"summary" => summary, "differences" => differences}}
    end
  end

  # --------------------------------------------------------------------------
  # GF-748: Agent config diff (gf.agent.* projection)
  # --------------------------------------------------------------------------

  defp diff_agent_config(run_a, run_b) do
    [:model, :system_prompt_hash, :temperature, :version]
    |> Enum.flat_map(fn field ->
      val_a = Map.get(run_a, field)
      val_b = Map.get(run_b, field)

      if val_a == val_b do
        []
      else
        [
          %{
            "type" => "config_diff",
            "field" => Atom.to_string(field),
            "val_a" => val_a,
            "val_b" => val_b
          }
        ]
      end
    end)
  end

  # --------------------------------------------------------------------------
  # Loading
  # --------------------------------------------------------------------------

  defp load_run(run_id) do
    case Repo.get(Run, run_id) do
      nil ->
        {:error, :run_not_found}

      run ->
        spans =
          from(l in Ledger,
            where: l.run_id == ^run_id,
            order_by: [asc: l.epoch_id, asc: l.seq]
          )
          |> Repo.all()

        {:ok, %{run: run, spans: spans, tree: build_tree(spans)}}
    end
  end

  # Algorithm copied from trail_live.ex:298-308.
  defp build_tree(rows) do
    by_parent = Enum.group_by(rows, & &1.parent_span_id)
    roots = Map.get(by_parent, nil, [])
    Enum.map(roots, &attach(&1, by_parent))
  end

  defp attach(row, by_parent) do
    span_id = get_in(row.payload, ["span_id"]) || row.span_id
    children = if span_id, do: Map.get(by_parent, span_id, []), else: []
    %{row: row, children: Enum.map(children, &attach(&1, by_parent))}
  end

  # --------------------------------------------------------------------------
  # Eval validation
  # --------------------------------------------------------------------------

  defp check_same_eval(%{eval_id: a}, %{eval_id: b})
       when is_binary(a) and is_binary(b) and a != b,
       do: {:error, :different_eval}

  defp check_same_eval(_, _), do: :ok

  # --------------------------------------------------------------------------
  # Summary
  # --------------------------------------------------------------------------

  defp summarize(spans) do
    total =
      spans
      |> Enum.map(&duration_ms/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    %{"span_count" => length(spans), "total_duration_ms" => total}
  end

  # --------------------------------------------------------------------------
  # Tree diff
  # --------------------------------------------------------------------------

  defp diff_trees(roots_a, roots_b) do
    # GF-740: each top-level pair is one logical branch. The marker
    # `"deviation_point" => true` goes on the FIRST diff entry **inside** each
    # branch, not on the global index 0. Branches with no diff entries (identical
    # subtrees) contribute [] — `mark_deviation_points([])` is a no-op.
    # @moduledoc spec: "the first emitted diff per top-level branch".
    roots_a
    |> pair_by_name(roots_b)
    |> Enum.flat_map(fn pair -> mark_deviation_points(diff_for_pair(pair)) end)
  end

  defp pair_and_diff(nodes_a, nodes_b) do
    nodes_a
    |> pair_by_name(nodes_b)
    |> Enum.flat_map(&diff_for_pair/1)
  end

  defp diff_for_pair({:only_a, node}),
    do: [%{"span_name" => name(node), "type" => "span_removed"}]

  defp diff_for_pair({:only_b, node}),
    do: [%{"span_name" => name(node), "type" => "span_added"}]

  defp diff_for_pair({:both, a, b}), do: diff_pair(a, b)

  defp diff_pair(a, b) do
    duration_diff = duration_diff_entry(a, b)
    children_diffs = pair_and_diff(a.children, b.children)
    List.wrap(duration_diff) ++ children_diffs
  end

  defp duration_diff_entry(a, b) do
    da = duration_ms(a.row)
    db = duration_ms(b.row)

    cond do
      is_nil(da) or is_nil(db) ->
        nil

      da == 0 and db == 0 ->
        nil

      significant_diff?(da, db) ->
        %{
          "span_name" => name(a),
          "type" => "duration_diff",
          "run_a_ms" => da,
          "run_b_ms" => db
        }

      true ->
        nil
    end
  end

  defp significant_diff?(da, db) do
    base = max(da, 1)
    abs(db - da) / base > @duration_threshold
  end

  # Pair nodes by name preserving sibling order. For each unique name, zip
  # the i-th node from a-list with the i-th from b-list (position = relative
  # order among same-named siblings). Leftover → only_a/only_b.
  defp pair_by_name(nodes_a, nodes_b) do
    by_name_a = group_with_order(nodes_a)
    by_name_b = group_with_order(nodes_b)

    # Iterate over the union, BUT preserving order — a MapSet would shuffle deviation_point
    # across runs. Order: first the names from a (insertion order), then new ones from b.
    all_names = Enum.uniq(Map.keys(by_name_a) ++ Map.keys(by_name_b))

    Enum.flat_map(all_names, fn n ->
      list_a = Map.get(by_name_a, n, [])
      list_b = Map.get(by_name_b, n, [])
      max_len = max(length(list_a), length(list_b))

      Enum.map(0..(max_len - 1)//1, fn i ->
        a = Enum.at(list_a, i)
        b = Enum.at(list_b, i)

        cond do
          a && b -> {:both, a, b}
          a -> {:only_a, a}
          b -> {:only_b, b}
        end
      end)
    end)
  end

  defp group_with_order(nodes) do
    Enum.reduce(nodes, %{}, fn node, acc ->
      Map.update(acc, name(node), [node], &(&1 ++ [node]))
    end)
  end

  defp mark_deviation_points([]), do: []

  defp mark_deviation_points(diffs) when is_list(diffs) do
    [head | tail] = diffs
    [Map.put(head, "deviation_point", true) | tail]
  end

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  defp name(%{row: row}), do: row.event_type

  defp duration_ms(%{row: row}), do: duration_ms(row)

  # Payload first: ISO8601 strings in the payload have sub-second precision.
  # The GF-669 projection columns row.started_at/ended_at are truncated to :second
  # (DateTime.truncate(:second) in Ledger.build_entry/7), which would compute sub-second
  # durations as 0.
  defp duration_ms(%{payload: payload} = row) do
    case duration_from_payload(payload) do
      ms when is_integer(ms) -> ms
      _ -> duration_from_projection(row)
    end
  end

  defp duration_ms(_), do: nil

  defp duration_from_payload(payload) when is_map(payload) do
    with s when is_binary(s) <- Map.get(payload, "started_at"),
         e when is_binary(e) <- Map.get(payload, "ended_at"),
         {:ok, sdt, _} <- DateTime.from_iso8601(s),
         {:ok, edt, _} <- DateTime.from_iso8601(e) do
      DateTime.diff(edt, sdt, :millisecond)
    else
      _ -> nil
    end
  end

  defp duration_from_payload(_), do: nil

  defp duration_from_projection(%{started_at: %DateTime{} = s, ended_at: %DateTime{} = e}),
    do: DateTime.diff(e, s, :millisecond)

  defp duration_from_projection(_), do: nil
end
