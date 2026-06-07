defmodule SpanChain.Ingestion.SessionGenServer do
  @moduledoc """
  Per-run_id stavový proces — hash-chain ledger pro jednu session.

  ## Architektura po GF-751/GF-746

  SGS je **čistý in-memory hash-chain engine**: drží hash chain state
  (`epoch_id`, `seq`, `prev_hash`) a per-run `eval_id` jako metadata.
  Počítá hash pro každý příchozí span a okamžitě forwarduje hotové
  entries do `BufferProducer` (GenStage producer Broadway pipeline).

  **Žádný DB přístup z tohoto modulu.** Veškerá persistence — `ledger_entries`,
  `runs`, `evals` upserty — žije v `Pipeline.handle_batch/4` (GF-751
  + GF-746). Prerekvizita pro Postgres přechod (GF-704): race condition
  selhání jdou izolovat na jednu vrstvu změny.

  ## Ordering guarantee

  `ingest_spans/2` je `GenServer.call` (ne `cast`) — entries z jednoho POST
  jdou do hash chainu atomicky v pořadí ze vstupní listy, paralelní volání
  se serializují přes mailbox.

  Erlang FIFO mezi SGS a BufferProducer + Broadway `partition_by: run_id`
  v processoru = DB insert pořadí per-run zachováno.

  ## Eval association

  `state.eval_id` se přilepí ke každému entry mapě jako in-memory metadata
  field (`:eval_id`). Pipeline metadata fáze z něj derivuje `evals` upsert
  a `runs.eval_id` update. `Ledger.insert_batch/1` field ignoruje (Pipeline
  strippne před voláním — viz `pipeline.ex` handle_batch).

  ## Co tu BÝVALO před GF-751/GF-746 a už není

  Best-effort upserty do `runs` (GF-669) a `evals` (GF-706) tabulek se
  přesunuly do Pipeline metadata fází. Late-binding helper zůstává čistě
  stavový (state mutation + telemetry), bez DB akce.

  Batching, flushing, timery a retry logika se přesunula do `Pipeline` už v GF-667.
  Test seamy `insert_fun` + `retry_delay_ms` byly odstraněny tamtéž.
  """

  # GF-775: restart: :temporary — crashnutý SGS se NEauto-restartuje supervisorem
  # (stará default :permanent restartovala se stale stavem epoch 0/prev_hash nil →
  # corrupted chain, GF-768). Místo toho Registry zůstane prázdný a další ingest
  # přes SessionSupervisor.ensure_session/1 provede recovery (epoch rollover +
  # carried prev_hash) — recovery čte DB MIMO SGS, takže GF-751 (no Repo) drží.
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
    # GF-775: epoch_id/prev_hash předány recovery cestou (ensure_session/1) po
    # restartu. Defaulty (0 / nil) zachovávají chování pro nový run i pro callery,
    # kteří je nepředávají (router, replayer, stress_test, testy).
    epoch_id = Keyword.get(opts, :epoch_id, 0)
    prev_hash = Keyword.get(opts, :prev_hash)

    GenServer.start_link(
      __MODULE__,
      %{run_id: run_id, eval_id: eval_id, epoch_id: epoch_id, prev_hash: prev_hash},
      name: via_tuple(run_id)
    )
  end

  @doc "Registry name pro `run_id`. Bezpečné volat i pro neexistující sessions."
  def via_tuple(run_id), do: {:via, Registry, {@registry, run_id}}

  @doc """
  Sync dispatch spanů na session. Hashuje synchronně, forwarduje async do
  Broadway pipeline. Vrací `{:ok, count}` kde `count` je počet zpracovaných
  spanů, nebo `{:error, reason}` (session crash / timeout).

  Caller musí předtím `SessionSupervisor.ensure_session/1`.
  """
  @spec ingest_spans(String.t(), [map()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def ingest_spans(run_id, spans) when is_list(spans), do: ingest_spans(run_id, spans, [])

  @doc """
  GF-727: variant s `opts` pro per-call kontext. Aktuálně podporuje:

    * `:eval_id` — late-binding pro již běžící SGS (init dostane `nil`,
      pozdější OTLP batch dorazí s `gf.eval_id` v resource attrs).
      Idempotentní: první eval_id vyhraje, další volání jsou no-op.

  Po GF-751/GF-746 je late-binding čistě stavová operace — DB upsert
  proběhne až při dalším Pipeline flushi přes `:eval_id` přilepený k entries.

  Public API `/2` zůstává beze změny pro `/ingest` JSON cestu (která eval_id
  nepoužívá). Internal message má vždy tvar `{:ingest_spans, spans, opts}`.
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

  @doc "Vrátí stav (hash chain pozici) — pro testy a introspekci."
  def snapshot(run_id) do
    GenServer.call(via_tuple(run_id), :snapshot)
  end

  # --------------------------------------------------------------------------
  # Server callbacks
  # --------------------------------------------------------------------------

  @impl true
  def init(%{run_id: run_id, eval_id: eval_id, epoch_id: epoch_id, prev_hash: prev_hash}) do
    # GF-775: epoch_id/prev_hash z recovery (ensure_session/1). seq vždy 0 —
    # nová epocha má vlastní sekvence prostor; prev_hash navazuje na poslední
    # commitnutý hash předchozí epochy (GF-666 cross-epoch kontinuita).
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

  # Reduce přes spans, pro každý spočítá hash a aktualizuje seq+prev_hash.
  # Vrací (entries, new_state) — žádný DB přístup, žádný timer, čistá funkce
  # (jen state mutation skrz GenServer reduce).
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

    # GF-666: prev_hash se zachovává přes epoch boundary — první záznam nové
    # epochy navazuje na poslední hash předchozí epochy. Bez toho je verify_ledger/1
    # imunní vůči smazání celé epochy (Island Attack).
    %{state | epoch_id: state.epoch_id + 1, seq: 0, prev_hash: state.prev_hash}
  end

  defp maybe_epoch_boundary(state), do: state

  # GF-727: late-binding pomocník. Volán z handle_call({:ingest_spans, _, opts}).
  # First-wins: pokud state.eval_id už non-nil, ignoruj.
  # Po GF-751/GF-746: čistě stavová operace + telemetry; DB upsert proběhne
  # při dalším Pipeline flushi přes `:eval_id` přilepený k entries v append_span.
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
