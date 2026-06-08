defmodule SpanChain.Ingestion.SessionGenServer do
  @moduledoc """
  Per-run_id stateful process — the hash-chain ledger for a single session.

  ## Architecture after GF-751/GF-746

  The SGS is a **pure in-memory hash-chain engine**: it holds the hash chain state
  (`epoch_id`, `seq`, `prev_hash`) and the per-run `eval_id` as metadata.
  It computes the hash for each incoming span and immediately forwards the finished
  entries to `BufferProducer` (the GenStage producer of the Broadway pipeline).

  **No DB access from this module.** All persistence — `ledger_entries`,
  `runs`, `evals` upserts — lives in `Pipeline.handle_batch/4` (GF-751
  + GF-746). A prerequisite for the Postgres migration (GF-704): race-condition
  failures can be isolated to a single layer of change.

  ## Ordering guarantee

  `ingest_spans/2` is a `GenServer.call` (not a `cast`) — entries from a single POST
  go into the hash chain atomically in the order of the input list, and parallel calls
  serialize through the mailbox.

  Erlang FIFO between the SGS and BufferProducer + Broadway `partition_by: run_id`
  in the processor = per-run DB insert order is preserved.

  ## Eval association

  `state.eval_id` is attached to every entry map as an in-memory metadata
  field (`:eval_id`). The Pipeline metadata phase derives the `evals` upsert
  and the `runs.eval_id` update from it. `Ledger.insert_batch/1` ignores the field (the Pipeline
  strips it before the call — see `pipeline.ex` handle_batch).

  ## What USED to be here before GF-751/GF-746 and no longer is

  Best-effort upserts into the `runs` (GF-669) and `evals` (GF-706) tables
  moved into the Pipeline metadata phases. The late-binding helper stays purely
  stateful (state mutation + telemetry), with no DB action.

  Batching, flushing, timers, and the retry logic already moved into `Pipeline` in GF-667.
  The `insert_fun` + `retry_delay_ms` test seams were removed there too.
  """

  # GF-775: restart: :temporary — a crashed SGS does NOT auto-restart via the supervisor
  # (the old default :permanent restarted with stale state epoch 0/prev_hash nil →
  # corrupted chain, GF-768). Instead the Registry stays empty and the next ingest
  # via SessionSupervisor.ensure_session/1 performs recovery (epoch rollover +
  # carried prev_hash) — recovery reads the DB OUTSIDE the SGS, so GF-751 (no Repo) holds.
  use GenServer, restart: :temporary

  alias SpanChain.Ledger
  alias SpanChain.Ingestion.BufferProducer

  @epoch_size 1_000

  @registry SpanChain.Ingestion.SessionRegistry

  @type state :: %{
          run_id: String.t(),
          eval_id: String.t() | nil,
          epoch_id: non_neg_integer(),
          seq: non_neg_integer(),
          prev_hash: String.t() | nil
        }

  # --------------------------------------------------------------------------
  # Client API
  # --------------------------------------------------------------------------

  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    eval_id = Keyword.get(opts, :eval_id)
    # GF-775: epoch_id/prev_hash passed via the recovery path (ensure_session/1) after
    # a restart. The defaults (0 / nil) preserve behavior for a new run and for callers
    # that don't pass them (router, replayer, stress_test, tests).
    epoch_id = Keyword.get(opts, :epoch_id, 0)
    prev_hash = Keyword.get(opts, :prev_hash)

    GenServer.start_link(
      __MODULE__,
      %{run_id: run_id, eval_id: eval_id, epoch_id: epoch_id, prev_hash: prev_hash},
      name: via_tuple(run_id)
    )
  end

  @doc "Registry name for `run_id`. Safe to call even for nonexistent sessions."
  def via_tuple(run_id), do: {:via, Registry, {@registry, run_id}}

  @doc """
  Sync dispatch of spans to the session. Hashes synchronously, forwards async to the
  Broadway pipeline. Returns `{:ok, count}` where `count` is the number of processed
  spans, or `{:error, reason}` (session crash / timeout).

  The caller must first call `SessionSupervisor.ensure_session/1`.
  """
  @spec ingest_spans(String.t(), [map()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def ingest_spans(run_id, spans) when is_list(spans), do: ingest_spans(run_id, spans, [])

  @doc """
  GF-727: a variant with `opts` for per-call context. Currently supports:

    * `:eval_id` — late-binding for an already-running SGS (init receives `nil`,
      a later OTLP batch arrives with `gf.eval_id` in the resource attrs).
      Idempotent: the first eval_id wins, further calls are a no-op.

  After GF-751/GF-746 late-binding is a purely stateful operation — the DB upsert
  happens on the next Pipeline flush via the `:eval_id` attached to the entries.

  The public API `/2` stays unchanged for the `/ingest` JSON path (which does not use
  eval_id). The internal message always has the form `{:ingest_spans, spans, opts}`.
  """
  @spec ingest_spans(String.t(), [map()], keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def ingest_spans(run_id, spans, opts) when is_list(spans) and is_list(opts) do
    try do
      GenServer.call(via_tuple(run_id), {:ingest_spans, spans, opts}, 10_000)
    catch
      :exit, reason -> {:error, reason}
    end
  end

  @doc "Returns the state (hash chain position) — for tests and introspection."
  def snapshot(run_id) do
    GenServer.call(via_tuple(run_id), :snapshot)
  end

  # --------------------------------------------------------------------------
  # Server callbacks
  # --------------------------------------------------------------------------

  @impl true
  def init(%{run_id: run_id, eval_id: eval_id, epoch_id: epoch_id, prev_hash: prev_hash}) do
    # GF-775: epoch_id/prev_hash from recovery (ensure_session/1). seq is always 0 —
    # a new epoch has its own sequence space; prev_hash chains onto the last
    # committed hash of the previous epoch (GF-666 cross-epoch continuity).
    {:ok, %{run_id: run_id, eval_id: eval_id, epoch_id: epoch_id, seq: 0, prev_hash: prev_hash}}
  end

  @impl true
  def handle_call({:ingest_spans, spans, opts}, _from, state) do
    state = maybe_apply_late_eval_id(state, Keyword.get(opts, :eval_id))
    {entries, new_state} = build_entries(spans, state)
    :ok = BufferProducer.enqueue(entries)
    {:reply, {:ok, length(entries)}, new_state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  # --------------------------------------------------------------------------
  # Private — pure hash chain builder
  # --------------------------------------------------------------------------

  # Reduce over the spans, computing a hash for each and updating seq+prev_hash.
  # Returns (entries, new_state) — no DB access, no timer, a pure function
  # (just state mutation through the GenServer reduce).
  defp build_entries(spans, state) do
    {entries_rev, final_state} =
      Enum.reduce(spans, {[], state}, fn span, {acc, st} ->
        {entry, new_st} =
          st
          |> append_span(span)

        {[entry | acc], new_st |> maybe_epoch_boundary()}
      end)

    {Enum.reverse(entries_rev), final_state}
  end

  defp append_span(state, span) do
    event_type = Map.get(span, "name") || Map.get(span, :name) || "span"
    parent_span_id = Map.get(span, "parent_span_id") || Map.get(span, :parent_span_id)
    payload = normalize_payload(span)

    entry =
      Ledger.build_entry(
        state.run_id,
        state.epoch_id,
        state.seq,
        state.prev_hash,
        event_type,
        payload,
        parent_span_id
      )
      |> Map.put(:eval_id, state.eval_id)

    new_state = %{state | prev_hash: entry.hash, seq: state.seq + 1}
    {entry, new_state}
  end

  defp normalize_payload(span) when is_map(span) do
    Map.new(span, fn {k, v} -> {to_string(k), v} end)
  end

  defp maybe_epoch_boundary(%{seq: seq} = state) when seq > 0 and rem(seq, @epoch_size) == 0 do
    :telemetry.execute(
      [:gf, :epoch, :boundary],
      %{count: 1},
      %{run_id: state.run_id, from_epoch: state.epoch_id, to_epoch: state.epoch_id + 1}
    )

    # GF-666: prev_hash is preserved across the epoch boundary — the first record of the new
    # epoch chains onto the last hash of the previous epoch. Without it verify_ledger/1
    # is blind to the deletion of a whole epoch (Island Attack).
    %{state | epoch_id: state.epoch_id + 1, seq: 0, prev_hash: state.prev_hash}
  end

  defp maybe_epoch_boundary(state), do: state

  # GF-727: late-binding helper. Called from handle_call({:ingest_spans, _, opts}).
  # First-wins: if state.eval_id is already non-nil, ignore.
  # After GF-751/GF-746: a purely stateful operation + telemetry; the DB upsert happens
  # on the next Pipeline flush via the `:eval_id` attached to the entries in append_span.
  defp maybe_apply_late_eval_id(state, nil), do: state

  defp maybe_apply_late_eval_id(%{eval_id: existing} = state, _new) when not is_nil(existing),
    do: state

  defp maybe_apply_late_eval_id(state, eval_id) when is_binary(eval_id) do
    :telemetry.execute(
      [:gf, :sgs, :late_bind_eval_id],
      %{count: 1},
      %{run_id: state.run_id, eval_id: eval_id}
    )

    %{state | eval_id: eval_id}
  end
end
