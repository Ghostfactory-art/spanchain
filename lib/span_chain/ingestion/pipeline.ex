defmodule SpanChain.Ingestion.Pipeline do
  @moduledoc """
  Broadway pipeline for asynchronous persistence of Ledger entries (GF-667).

  Consumes messages from `BufferProducer` (or `Broadway.DummyProducer` in tests)
  and calls `Ledger.insert_batch/1` in batches. On failure it retries 3× with exponential
  backoff (preserves the GF-645 semantics, just moved out of SessionGenServer).

  ## Ordering / partitioning (GF-779)

  The batcher uses `partition_by: fn msg -> :erlang.phash2(msg.data.run_id) end` —
  the same `run_id` always goes to the same batcher partition (per-session locality),
  different `run_id`s run in parallel (cross-session concurrency on Postgres MVCC).
  It MUST hash: Broadway computes `rem(func.(msg), concurrency)`, a bare string
  `run_id` would crash with `ArithmeticError`. Hash-chain integrity does not depend on
  DB insert order (it is computed in-memory in `SessionGenServer`; `verify_ledger`
  reads `order_by: seq`).

  ## Concurrency (GF-779, post-Postgres GF-704)

  Processors `concurrency: System.schedulers_online()`, batcher `concurrency: 4`.
  The producer stays `concurrency: 1` (Registry singleton). Postgres MVCC replaced the
  SQLite single-writer limit. **The test env is pinned to 1** via the
  `:broadway_processor_concurrency` / `:broadway_batcher_concurrency` seams.

  ## Configuration via Application env

  - `:broadway_producer_module` — `BufferProducer` (prod/dev) or
    `Broadway.DummyProducer` (test, enables `Broadway.test_message/3`)
  - `:broadway_batch_timeout_ms` — 100ms (prod/dev, GF-777) / 50ms (test);
    tunable in prod via the `BATCH_FLUSH_TIMEOUT_MS` env var (config/runtime.exs)
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

    # GF-777: default 100ms (was 1000ms). Broadway flushes on the FIRST satisfied
    # condition (batch_size 50 OR batch_timeout) → a lower timeout drops the low-volume
    # p99 from ~1034ms to ~100ms. The earlier "don't lower the timeout — SQLITE_BUSY risk" is
    # obsolete after GF-704 (the Postgres pool handles a higher frequency of small batches).
    # Value source: config.exs default / test.exs seam 50ms / prod env var
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
        # GF-779: Postgres MVCC allows concurrent writes → processors scale with
        # the number of schedulers. We do NOT partition the processors (the per-message work is
        # a pure pass-through; partition_by belongs only on the batcher — CLAUDE.md).
        # Test env pinned to 1 via the :broadway_processor_concurrency seam.
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
          # GF-779: partition_by hashes run_id → the same run_id always to the same
          # batcher partition (per-session serialization), different run_ids in parallel.
          # MUST be :erlang.phash2/1 — Broadway computes rem(func.(msg), concurrency),
          # a bare string run_id would crash with ArithmeticError.
          concurrency: Application.get_env(:span_chain, :broadway_batcher_concurrency, 4),
          partition_by: fn msg -> :erlang.phash2(msg.data.run_id) end
        ]
      ]
    )
  end

  @impl Broadway
  def handle_message(_processor_name, message, _context) do
    # Pass-through — the batcher does the batching; the processor only partitions.
    message
  end

  @impl Broadway
  def handle_batch(:default, messages, _batch_info, _context) do
    entries = Enum.map(messages, & &1.data)
    ledger_mod = Application.get_env(:span_chain, :ledger_module, Ledger)

    # GF-751/GF-746: metadata upserts BEFORE the ledger insert.
    # Order: ensure_run_records → ensure_eval_records (FK runs.eval_id → evals.eval_id)
    # → upsert_agent_configs → insert_batch → broadcast.
    # Each metadata function has its own defensive rescue — a failure must NEVER
    # crash the Pipeline or block the ledger insert (the hash chain is the critical path).
    ensure_run_records(entries)
    ensure_eval_records(entries)
    upsert_agent_configs(entries)

    # `:eval_id` is SGS-side metadata (GF-751) — NOT a Ledger schema field.
    # Strip it before `insert_batch`, otherwise `Repo.insert_all(Ledger, ...)` raises on the unknown field.
    ledger_entries = Enum.map(entries, &Map.delete(&1, :eval_id))

    try do
      # GF-703: Repo.transaction as a WAL synchronization barrier. The {:ok, _} return
      # guarantees the commit happened → the data is visible to all WAL readers
      # → broadcast is the correct signal. The broadcast MUST come after the transaction returns,
      # never inside the transaction block.
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
          # GF-775: drain signal for crash recovery — ensure_session/1 waits on it
          # before the epoch rollover. After commit (read-after-write guaranteed).
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
      # Broadway gotcha: a raise in handle_batch crashes the supervisor (max_restarts 3/5s).
      # Always convert to Message.failed/2.
      e ->
        Logger.error("[Pipeline] handle_batch rescued #{inspect(e)}")
        Enum.map(messages, &Message.failed(&1, Exception.message(e)))
    end
  end

  # PubSub notify TrailLive after a successful batch insert (backlog #9+#10).
  # One-way dependency: the Pipeline knows PubSub, not the LiveView. Use broadcast/3
  # (not !) — a PubSub failure must not bring down the Pipeline.
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

  # GF-775: epoch-flush signal for the crash recovery drain. One broadcast per
  # unique {run_id, epoch_id} in the batch (per-epoch because of a possible mid-batch
  # 1000-event rollover). Same crash-safe pattern as safe_broadcast/1.
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
    # Broadway exhausted all attempts (in our configuration = 1 batch attempt).
    # DeadLetter.store is defensive — a failure of the store itself is only logged.
    dead_letter_mod = Application.get_env(:span_chain, :dead_letter_module, DeadLetter)

    Enum.each(messages, fn %Message{data: entry, status: status} ->
      reason =
        case status do
          {:failed, r} -> r
          other -> inspect(other)
        end

      # The stub may itself raise — handle_failed must not crash Broadway.
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

    # Broadway requirement: handle_failed ALWAYS returns messages (even empty).
    messages
  end

  # --------------------------------------------------------------------------
  # GF-751: ensure runs/evals records — moved out of SessionGenServer.init/1 and
  # maybe_apply_late_eval_id. The SGS is now a pure in-memory hash chain without
  # DB side-effects; the metadata upserts happen inside the Broadway batch.
  # --------------------------------------------------------------------------

  # Per-batch upsert into the `runs` table on the PK `run_id`. GF-790: on_conflict updates
  # ONLY `started_at` via LEAST (the oldest span across batches); the other columns
  # (status/agent_name/…) stay untouched → idempotent with respect to metadata.
  # Defensive: a failure must NEVER crash the Pipeline.
  @doc false
  def ensure_run_records(entries) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      entries
      |> Enum.group_by(& &1.run_id)
      |> Enum.map(fn {run_id, run_entries} ->
        # GF-790: the oldest started_at from this batch for the given run (nil-safe). A batch
        # may contain multiple run_ids → we compute min per run, not across the whole batch.
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
        # GF-790: LEAST upsert — runs.started_at converges to the oldest span
        # across batches (out-of-order ingest). Postgres LEAST ignores NULL
        # (nil-safe). Changes started_at EXCLUSIVELY; status/agent_name/… stay
        # (handled by ensure_eval_records / upsert_agent_configs). Query form of on_conflict
        # (not the keyword `set:`) — `fragment` only expands in an Ecto query context;
        # `?` binds the existing row (`r.started_at`), `EXCLUDED` is the proposed row.
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

  # GF-746: per-batch upsert into `evals` + `runs.eval_id` update.
  # Internal order: Eval insert FIRST (the FK target for runs.eval_id), then the Run update.
  # COALESCE first-wins on runs.eval_id for GF-727 idempotence — a second batch
  # with a different eval_id for the same run_id does not overwrite the first (same pattern as
  # `maybe_update_run_agent_config`). Defensive rescue like `ensure_run_records`.
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

  # Per-run extraction of gf.agent.* attrs + COALESCE upsert into `runs`.
  # Defensive: an error must NEVER crash the Pipeline (gf.agent.* is metadata,
  # not the critical path). Called AFTER broadcast_flushed (transaction committed,
  # connection released — safe from the Broadway processor PID).
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
    # COALESCE(existing, new) = first-wins. If Run.model is already non-nil (from the GF-669
    # SGS ensure_run_record path), it is kept. Otherwise it is filled with the new value.
    # The pin (`^`) in `set:` must be inside the Ecto query DSL — hence `from(..., update: ...)`
    # instead of `set:` as Repo.update_all/3 opts.
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
  # Private — retry helper (per CLAUDE.md Do NOT: don't share across modules)
  # --------------------------------------------------------------------------

  # 3 attempts, exp backoff 500/1000/2000 ms (~3.5s worst case). Same semantics
  # as the former SessionGenServer.with_retry before the GF-667 refactor.
  # The `delay_ms` default reads runtime config — test env overrides to 1ms (config/test.exs).
  #
  # GF-704 decision: Scenario B — blanket retry, no SQLite-specific patterns.
  # `try_fun/1` catches any exception/throw, so transient Postgres errors
  # (DBConnection.ConnectionError, :queue_timeout) are covered unchanged. The catch-all is
  # KEPT deliberately — narrowing it to specific rescue clauses would reduce coverage.
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
