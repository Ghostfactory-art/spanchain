defmodule SpanChain.Ingestion.Pipeline do
  @moduledoc """
  Broadway pipeline pro asynchronní persistenci Ledger entries (GF-667).

  Konzumuje messages z `BufferProducer` (nebo `Broadway.DummyProducer` v testech)
  a batchovaně volá `Ledger.insert_batch/1`. Při selhání retry 3× s exponenciálním
  backoffem (zachovává GF-645 sémantiku, jen přesunutou z SessionGenServer).

  ## Ordering / partitioning (GF-779)

  Batcher používá `partition_by: fn msg -> :erlang.phash2(msg.data.run_id) end` —
  stejný `run_id` jde vždy do stejné batcher partition (per-session lokalita),
  různé `run_id`s běží paralelně (cross-session souběžnost na Postgres MVCC).
  MUSÍ hashovat: Broadway počítá `rem(func.(msg), concurrency)`, bare string
  `run_id` by spadl na `ArithmeticError`. Hash-chain integrita na DB insert
  pořadí nezávisí (počítá se in-memory v `SessionGenServer`; `verify_ledger`
  čte `order_by: seq`).

  ## Concurrency (GF-779, post-Postgres GF-704)

  Procesory `concurrency: System.schedulers_online()`, batcher `concurrency: 4`.
  Producer zůstává `concurrency: 1` (Registry singleton). Postgres MVCC nahradil
  SQLite single-writer limit. **Test env je pinováno na 1** přes seamy
  `:broadway_processor_concurrency` / `:broadway_batcher_concurrency`.

  ## Konfigurace přes Application env

  - `:broadway_producer_module` — `BufferProducer` (prod/dev) nebo
    `Broadway.DummyProducer` (test, umožňuje `Broadway.test_message/3`)
  - `:broadway_batch_timeout_ms` — 100ms (prod/dev, GF-777) / 50ms (test);
    prod laditelný přes `BATCH_FLUSH_TIMEOUT_MS` env var (config/runtime.exs)
  - `:broadway_processor_concurrency` — default `System.schedulers_online()` / 1 (test)
  - `:broadway_batcher_concurrency` — default 4 / 1 (test)
  """

  use Broadway
  require Logger
  import Ecto.Query, only: [from: 2]

  alias Broadway.Message
  alias SpanChain.{DeadLetter, Ledger, Repo, Run}

  @retry_attempts 3
  @retry_initial_delay_ms 500

  def start_link(_opts) do
    producer_module =
      Application.fetch_env!(:span_chain, :broadway_producer_module)

    # GF-777: default 100ms (bylo 1000ms). Broadway flushuje na PRVNÍ splněnou
    # podmínku (batch_size 50 NEBO batch_timeout) → nižší timeout sráží low-volume
    # p99 z ~1034ms k ~100ms. Dřívější "nesniž timeout — SQLITE_BUSY risk" je
    # obsolete po GF-704 (Postgres pool zvládá vyšší frekvenci malých batchů).
    # Zdroj hodnoty: config.exs default / test.exs seam 50ms / prod env var
    # BATCH_FLUSH_TIMEOUT_MS (runtime.exs). Fallback 100 = config.exs default.
    batch_timeout =
      Application.get_env(:span_chain, :broadway_batch_timeout_ms, 100)

    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {producer_module, []},
        concurrency: 1
      ],
      processors: [
        # GF-779: Postgres MVCC umožňuje souběžné zápisy → procesory škálují s
        # počtem schedulerů. Procesory NEpartitionujeme (per-message práce je
        # pure pass-through; partition_by patří jen na batcher — CLAUDE.md).
        # Test env pinováno na 1 přes :broadway_processor_concurrency seam.
        default: [
          concurrency:
            Application.get_env(
              :span_chain,
              :broadway_processor_concurrency,
              System.schedulers_online()
            )
        ]
      ],
      batchers: [
        default: [
          batch_size: 50,
          batch_timeout: batch_timeout,
          # GF-779: partition_by hashuje run_id → stejný run_id vždy na stejnou
          # batcher partition (serializace per session), různé run_ids paralelně.
          # MUSÍ být :erlang.phash2/1 — Broadway počítá rem(func.(msg), concurrency),
          # bare string run_id by spadl na ArithmeticError.
          concurrency: Application.get_env(:span_chain, :broadway_batcher_concurrency, 4),
          partition_by: fn msg -> :erlang.phash2(msg.data.run_id) end
        ]
      ]
    )
  end

  @impl Broadway
  def handle_message(_processor_name, message, _context) do
    # Pass-through — batching dělá batcher; processor jen partitionuje.
    message
  end

  @impl Broadway
  def handle_batch(:default, messages, _batch_info, _context) do
    entries = Enum.map(messages, & &1.data)
    ledger_mod = Application.get_env(:span_chain, :ledger_module, Ledger)

    # GF-751/GF-746: metadata upserty PŘED ledger insert.
    # Pořadí: ensure_run_records → ensure_eval_records (FK runs.eval_id → evals.eval_id)
    # → upsert_agent_configs → insert_batch → broadcast.
    # Každá metadata funkce má vlastní defensive rescue — selhání NIKDY nesmí
    # crashnout Pipeline ani zablokovat ledger insert (hash chain je kritická cesta).
    ensure_run_records(entries)
    ensure_eval_records(entries)
    upsert_agent_configs(entries)

    # `:eval_id` je SGS-side metadata (GF-751) — NE Ledger schema field.
    # Strip před `insert_batch`, jinak `Repo.insert_all(Ledger, ...)` raise na unknown field.
    ledger_entries = Enum.map(entries, &Map.delete(&1, :eval_id))

    try do
      # GF-703: Repo.transaction jako WAL synchronizační bariéra. {:ok, _} return
      # je garance, že commit proběhl → data jsou viditelná pro všechny WAL readery
      # → broadcast je správný signál. Broadcast MUSÍ být po returnu z transakce,
      # nikdy uvnitř transakčního bloku.
      result =
        with_retry(fn ->
          case Repo.transaction(fn -> ledger_mod.insert_batch(ledger_entries) end) do
            {:ok, _} = ok -> ok
            {:error, _} = err -> err
          end
        end)

      case result do
        {:ok, _result} ->
          broadcast_flushed(entries)
          # GF-775: drain signál pro crash recovery — ensure_session/1 na něj čeká
          # před epoch rolloverem. Po commitu (read-after-write garantován).
          broadcast_epoch_flushed(entries)
          messages

        {:error, reason} ->
          Logger.error(
            "[Pipeline] insert_batch exhausted retries count=#{length(entries)} " <>
              "reason=#{inspect(reason)}"
          )

          Enum.map(messages, &Message.failed(&1, inspect(reason)))
      end
    rescue
      # Broadway gotcha: raise v handle_batch crashne supervisor (max_restarts 3/5s).
      # Vždy konvertovat na Message.failed/2.
      e ->
        Logger.error("[Pipeline] handle_batch rescued #{inspect(e)}")
        Enum.map(messages, &Message.failed(&1, Exception.message(e)))
    end
  end

  # PubSub notify TrailLive po úspěšném batch insertu (backlog #9+#10).
  # Jednosměrná závislost: Pipeline zná PubSub, ne LiveView. Použít broadcast/3
  # (nikoli !) — failure PubSub nesmí padnout Pipeline.
  defp broadcast_flushed(entries) do
    entries
    |> Enum.map(& &1.run_id)
    |> Enum.uniq()
    |> Enum.each(&safe_broadcast/1)
  end

  defp safe_broadcast(run_id) do
    try do
      Phoenix.PubSub.broadcast(
        SpanChain.PubSub,
        "run:#{run_id}",
        {:spans_flushed, run_id}
      )

      Phoenix.PubSub.broadcast(
        SpanChain.PubSub,
        "runs",
        {:run_updated, run_id}
      )
    rescue
      e ->
        Logger.warning(
          "[Pipeline] PubSub broadcast skipped run_id=#{run_id} reason=#{inspect(e)}"
        )
    catch
      kind, value ->
        Logger.warning(
          "[Pipeline] PubSub broadcast caught #{kind}=#{inspect(value)} run_id=#{run_id}"
        )
    end
  end

  # GF-775: epoch-flush signál pro crash recovery drain. Jeden broadcast per
  # unikátní {run_id, epoch_id} v dávce (per-epoch kvůli možnému mid-batch
  # 1000-event rolloveru). Stejný crash-safe pattern jako safe_broadcast/1.
  defp broadcast_epoch_flushed(entries) do
    entries
    |> Enum.map(&{&1.run_id, &1.epoch_id})
    |> Enum.uniq()
    |> Enum.each(fn {run_id, epoch_id} -> safe_broadcast_epoch(run_id, epoch_id) end)
  end

  defp safe_broadcast_epoch(run_id, epoch_id) do
    try do
      Phoenix.PubSub.broadcast(
        SpanChain.PubSub,
        "epoch_flush:#{run_id}",
        {:epoch_flushed, run_id, epoch_id}
      )
    rescue
      e ->
        Logger.warning(
          "[Pipeline] epoch_flush broadcast skipped run_id=#{run_id} reason=#{inspect(e)}"
        )
    catch
      kind, value ->
        Logger.warning(
          "[Pipeline] epoch_flush broadcast caught #{kind}=#{inspect(value)} run_id=#{run_id}"
        )
    end
  end

  @impl Broadway
  def handle_failed(messages, _context) do
    # Broadway vyčerpalo všechny pokusy (v naší konfiguraci = 1 batch attempt).
    # DeadLetter.store je defenzivní — failure samotného store je jen logged.
    dead_letter_mod = Application.get_env(:span_chain, :dead_letter_module, DeadLetter)

    Enum.each(messages, fn %Message{data: entry, status: status} ->
      reason =
        case status do
          {:failed, r} -> r
          other -> inspect(other)
        end

      # Stub může i sám raise — handle_failed nesmí crashnout Broadway.
      try do
        _ = dead_letter_mod.store(entry.run_id, [entry], reason)
      rescue
        e ->
          Logger.error(
            "[Pipeline] dead_letter store rescued run_id=#{entry.run_id} " <>
              "error=#{inspect(e)} original_reason=#{inspect(reason)}"
          )
      catch
        kind, value ->
          Logger.error(
            "[Pipeline] dead_letter store caught #{kind}=#{inspect(value)} " <>
              "run_id=#{entry.run_id} original_reason=#{inspect(reason)}"
          )
      end
    end)

    run_ids = messages |> Enum.map(& &1.data.run_id) |> Enum.uniq()

    :telemetry.execute(
      [:gf, :flush, :dead_letter],
      %{count: length(messages)},
      %{run_ids: run_ids}
    )

    # Broadway requirement: handle_failed VŽDY vrátí messages (i prázdné).
    messages
  end

  # --------------------------------------------------------------------------
  # GF-751: ensure runs/evals záznamy — přesun z SessionGenServer.init/1 a
  # maybe_apply_late_eval_id. SGS je nyní čistý in-memory hash chain bez
  # DB side-efektů; metadata upserty probíhají uvnitř Broadway batche.
  # --------------------------------------------------------------------------

  # Per-batch upsert do `runs` tabulky na PK `run_id`. GF-790: on_conflict aktualizuje
  # POUZE `started_at` přes LEAST (nejstarší span napříč dávkami); ostatní sloupce
  # (status/agent_name/…) zůstávají nedotčené → idempotentní vůči metadatům.
  # Defensive: failure NIKDY nesmí crashnout Pipeline.
  @doc false
  def ensure_run_records(entries) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      entries
      |> Enum.group_by(& &1.run_id)
      |> Enum.map(fn {run_id, run_entries} ->
        # GF-790: nejstarší started_at z této dávky pro daný run (nil-safe). Dávka
        # může obsahovat víc run_ids → min počítáme per run, ne přes celý batch.
        started_at =
          run_entries
          |> Enum.map(&Map.get(&1, :started_at))
          |> Enum.reject(&is_nil/1)
          |> Enum.min(DateTime, fn -> nil end)

        %{run_id: run_id, status: "running", started_at: started_at, inserted_at: now}
      end)

    case rows do
      [] ->
        :ok

      _ ->
        # GF-790: LEAST upsert — runs.started_at konverguje k nejstaršímu spanu
        # napříč dávkami (out-of-order ingest). Postgres LEAST ignoruje NULL
        # (nil-safe). Mění VÝHRADNĚ started_at; status/agent_name/… zůstávají
        # (řeší ensure_eval_records / upsert_agent_configs). Query forma on_conflict
        # (ne keyword `set:`) — `fragment` se rozbaluje jen v Ecto query kontextu;
        # `?` váže existující řádek (`r.started_at`), `EXCLUDED` je navrhovaný řádek.
        Repo.insert_all("runs", rows,
          on_conflict:
            from(r in "runs",
              update: [
                set: [started_at: fragment("LEAST(EXCLUDED.started_at, ?)", r.started_at)]
              ]
            ),
          conflict_target: [:run_id]
        )
    end

    :ok
  rescue
    e ->
      Logger.warning("[Pipeline] ensure_run_records rescued #{inspect(e)}")
      :ok
  catch
    kind, value ->
      Logger.warning("[Pipeline] ensure_run_records caught #{kind}=#{inspect(value)}")
      :ok
  end

  # GF-746: per-batch upsert do `evals` + `runs.eval_id` update.
  # Pořadí uvnitř: Eval insert PRVNÍ (FK target pro runs.eval_id), pak Run update.
  # COALESCE first-wins na runs.eval_id pro GF-727 idempotenci — druhý batch
  # s jiným eval_id pro stejný run_id nepřepíše první (stejný pattern jako
  # `maybe_update_run_agent_config`). Defensive rescue jako `ensure_run_records`.
  @doc false
  def ensure_eval_records(entries) do
    pairs =
      entries
      |> Enum.filter(&Map.get(&1, :eval_id))
      |> Enum.uniq_by(&{&1.run_id, &1.eval_id})

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    eval_rows =
      pairs
      |> Enum.uniq_by(& &1.eval_id)
      |> Enum.map(fn entry ->
        %{eval_id: entry.eval_id, status: "running", inserted_at: now, updated_at: now}
      end)

    case eval_rows do
      [] ->
        :ok

      _ ->
        Repo.insert_all("evals", eval_rows,
          on_conflict: :nothing,
          conflict_target: [:eval_id]
        )
    end

    Enum.each(pairs, fn entry ->
      from(r in Run,
        where: r.run_id == ^entry.run_id,
        update: [set: [eval_id: fragment("COALESCE(eval_id, ?)", ^entry.eval_id)]]
      )
      |> Repo.update_all([])
    end)

    :ok
  rescue
    e ->
      Logger.warning("[Pipeline] ensure_eval_records rescued #{inspect(e)}")
      :ok
  catch
    kind, value ->
      Logger.warning("[Pipeline] ensure_eval_records caught #{kind}=#{inspect(value)}")
      :ok
  end

  # --------------------------------------------------------------------------
  # GF-748: gf.agent.* projection upsert (first-wins via COALESCE)
  # --------------------------------------------------------------------------

  # Per-run extraction of gf.agent.* attrs + COALESCE upsert do `runs`.
  # Defensive: chyba NIKDY nesmí crashnout Pipeline (gf.agent.* je metadata,
  # ne kritická cesta). Volá se POST broadcast_flushed (transakce commitnuta,
  # connection released — bezpečné z Broadway processor PID).
  @doc false
  def upsert_agent_configs(entries) do
    entries
    |> Enum.group_by(& &1.run_id)
    |> Enum.each(fn {run_id, run_entries} ->
      case extract_agent_config(run_entries) do
        nil -> :ok
        config -> maybe_update_run_agent_config(run_id, config)
      end
    end)
  rescue
    e ->
      Logger.warning("[Pipeline] gf.agent.* upsert rescued #{inspect(e)}")
      :ok
  catch
    kind, value ->
      Logger.warning("[Pipeline] gf.agent.* upsert caught #{kind}=#{inspect(value)}")
      :ok
  end

  @doc false
  def extract_agent_config(entries) do
    Enum.find_value(entries, fn entry ->
      attrs = get_in(entry.payload, ["attributes"]) || %{}

      case Map.get(attrs, "gf.agent.model") do
        model when is_binary(model) ->
          %{
            model: model,
            system_prompt_hash: Map.get(attrs, "gf.agent.system_prompt_hash"),
            temperature: Map.get(attrs, "gf.agent.temperature"),
            version: Map.get(attrs, "gf.agent.version")
          }

        _ ->
          nil
      end
    end)
  end

  @doc false
  def maybe_update_run_agent_config(run_id, config) do
    # COALESCE(existing, new) = first-wins. Pokud Run.model už non-nil (z GF-669
    # SGS ensure_run_record path), zachová se. Jinak vyplní novou hodnotou.
    # Pin (`^`) v `set:` musí být uvnitř Ecto query DSL — proto `from(..., update: ...)`
    # místo `set:` jako Repo.update_all/3 opts.
    from(r in Run,
      where: r.run_id == ^run_id,
      update: [
        set: [
          model: fragment("COALESCE(model, ?)", ^config.model),
          system_prompt_hash:
            fragment("COALESCE(system_prompt_hash, ?)", ^config.system_prompt_hash),
          temperature: fragment("COALESCE(temperature, ?)", ^config.temperature),
          version: fragment("COALESCE(version, ?)", ^config.version)
        ]
      ]
    )
    |> Repo.update_all([])

    :ok
  end

  # --------------------------------------------------------------------------
  # Private — retry helper (per CLAUDE.md Do NOT: nesdílet napříč moduly)
  # --------------------------------------------------------------------------

  # 3 pokusy, exp backoff 500/1000/2000 ms (~3.5s worst case). Stejná sémantika
  # jako bývalá SessionGenServer.with_retry před GF-667 refactorem.
  # `delay_ms` default čte runtime config — test env override na 1ms (config/test.exs).
  #
  # GF-704 decision: Scénář B — blanket retry, žádné SQLite-specifické patterny.
  # `try_fun/1` chytá libovolnou exception/throw, takže transientní Postgres chyby
  # (DBConnection.ConnectionError, :queue_timeout) jsou pokryté beze změny. Catch-all
  # ZACHOVÁN záměrně — zúžení na konkrétní rescue clauses by snížilo coverage.
  defp with_retry(
         fun,
         attempts \\ @retry_attempts,
         delay_ms \\ Application.get_env(
           :span_chain,
           :broadway_retry_initial_delay_ms,
           @retry_initial_delay_ms
         )
       )
       when is_function(fun, 0) and attempts >= 1 do
    case try_fun(fun) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} when attempts > 1 ->
        Logger.warning(
          "[Pipeline] insert retry remaining=#{attempts - 1} " <>
            "delay=#{delay_ms}ms reason=#{inspect(reason)}"
        )

        Process.sleep(delay_ms)
        with_retry(fun, attempts - 1, delay_ms * 2)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp try_fun(fun) do
    try do
      fun.()
    rescue
      e -> {:error, Exception.message(e)}
    catch
      kind, value -> {:error, "#{kind}: #{inspect(value)}"}
    end
  end
end
