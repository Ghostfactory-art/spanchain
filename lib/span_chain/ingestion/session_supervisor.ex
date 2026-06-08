defmodule SpanChain.Ingestion.SessionSupervisor do
  @moduledoc """
  DynamicSupervisor wrapper — race-safe spawn of a SessionGenServer per run_id.

  ## Crash recovery (GF-775)

  The SGS is `restart: :temporary` → a crash does NOT auto-restart. `ensure_session/1` on
  an empty Registry checks the DB for whether the `run_id` exists:
  - **new run** → spawn with epoch 0, prev_hash nil (defaults).
  - **restart** (run in the DB) → drain in-flight spans of the old epoch (PubSub `epoch_flush:`),
    then spawn with `epoch_id+1` and `prev_hash` = the last committed hash (preserves
    GF-666 cross-epoch continuity → `verify_ledger/1` stays `{:ok, _}`).

  The Repo read lives EXCLUSIVELY here — the SGS stays Repo-free (GF-751).
  """

  import Ecto.Query, only: [from: 2]

  alias SpanChain.{Ledger, Repo}
  alias SpanChain.Ingestion.SessionGenServer

  require Logger

  @supervisor __MODULE__
  @registry SpanChain.Ingestion.SessionRegistry

  @doc "Child spec for the Supervisor in Application."
  def child_spec(_opts) do
    DynamicSupervisor.child_spec(name: @supervisor, strategy: :one_for_one)
  end

  @doc """
  Returns the pid of the SessionGenServer for `run_id`. If the session does not exist,
  spawns it. The race condition between two concurrent calls is explicitly
  handled via `{:error, {:already_started, pid}}`.

  Optional `opts`:
    * `:eval_id` (GF-706) — passive association `run` ↔ `eval` at SGS init.
      Spawn-time-only: opts are applied only if the SGS actually spawns
      (an existing SGS for the same run_id ignores opts — eval_id was already
      persisted in its init).
  """
  @spec ensure_session(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_session(run_id, opts \\ []) when is_binary(run_id) do
    case Registry.lookup(@registry, run_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        recover_or_spawn(run_id, opts)
    end
  end

  # GF-775: Registry empty → either a new run, or a restart (the run is already in the DB).
  # Recovery: drain the old epoch, then spawn with a new epoch + carried prev_hash.
  defp recover_or_spawn(run_id, opts) do
    case fetch_last_epoch(run_id) do
      nil ->
        # New run — no DB records. Defaults epoch 0 / prev_hash nil.
        spawn_session(run_id, opts)

      last_epoch ->
        # Restart. Wait until the in-flight spans of the old epoch commit, then read
        # the actual last hash (Postgres read-after-write after commit, GF-704).
        await_epoch_drain(run_id, last_epoch)
        prev_hash = fetch_last_hash(run_id)
        spawn_session(run_id, [epoch_id: last_epoch + 1, prev_hash: prev_hash] ++ opts)
    end
  end

  # Repo reads — EXCLUSIVELY here, never in SessionGenServer (GF-751).
  defp fetch_last_epoch(run_id) do
    Repo.one(from(l in Ledger, where: l.run_id == ^run_id, select: max(l.epoch_id)))
  end

  defp fetch_last_hash(run_id) do
    Repo.one(
      from(l in Ledger,
        where: l.run_id == ^run_id,
        order_by: [desc: l.epoch_id, desc: l.seq],
        limit: 1,
        select: l.hash
      )
    )
  end

  # Waits for the in-flight batches of the old epoch to flush. `{:epoch_flushed}` is broadcast
  # by Pipeline.handle_batch after commit. Symmetric un/subscribe (unsubscribe is ALWAYS called).
  #
  # GF-782: "drain until silence" — after the FIRST flush of the old epoch, drain until
  # `silence_ms` of silence arrives. A burst > batch_size (50) = multiple batches in-flight; returning after
  # the FIRST flush (the previous behavior) let `fetch_last_hash` read a stale position → a new
  # epoch with a stale prev_hash → `verify_ledger` {:error, :chain_broken} (GF-666 regression).
  #
  # A cold-start guard is NOT needed: `await_epoch_drain/2` is called EXCLUSIVELY from the `last_epoch`
  # branch of `recover_or_spawn/2`; the `nil` branch (new run) goes directly to `spawn_session/2`.
  defp await_epoch_drain(run_id, old_epoch) do
    # GF-786: epoch_drain_timeout is NOT a config key — it is derived from the current batch_timeout, so
    # it stays in sync with the `BATCH_FLUSH_TIMEOUT_MS` runtime override (GF-777). 10× + 200ms buffer
    # preserves the GF-780 invariant (drain > batch_timeout) and the prod value 1_200ms (100*10+200; test
    # 50*10+200=700ms). Timeout path: if Broadway commits EVERYTHING BEFORE `subscribe` (a fast
    # Postgres), `receive` gets no message and returns :ok after timeout_ms → `fetch_last_hash` reads
    # the correct committed data (correct behavior, just latency; logs a warning below).
    batch_timeout = Application.get_env(:span_chain, :broadway_batch_timeout_ms, 100)
    timeout_ms = batch_timeout * 10 + 200

    # GF-782: silence_ms MUST be > batch_timeout (100ms prod after GF-777) — default 200ms = 2×.
    silence_ms = Application.get_env(:span_chain, :epoch_drain_silence_ms, 200)
    topic = "epoch_flush:#{run_id}"
    :ok = Phoenix.PubSub.subscribe(SpanChain.PubSub, topic)

    receive do
      {:epoch_flushed, ^run_id, ^old_epoch} ->
        drain_until_silence(run_id, old_epoch, silence_ms)
    after
      timeout_ms ->
        Logger.warning(
          "[SessionSupervisor] epoch drain timeout for run_id=#{run_id}, epoch=#{old_epoch} — " <>
            "assuming a missed broadcast, data should be committed"
        )

        :ok
    end

    Phoenix.PubSub.unsubscribe(SpanChain.PubSub, topic)
    :ok
  end

  # Drains until `silence_ms` of silence arrives after the LAST message for old_epoch. Each
  # further flush of the old epoch resets the silence window; messages for other epochs / run_ids are
  # ignored by the selective receive (they stay in the mailbox — a flush of another session).
  defp drain_until_silence(run_id, old_epoch, silence_ms) do
    receive do
      {:epoch_flushed, ^run_id, ^old_epoch} ->
        drain_until_silence(run_id, old_epoch, silence_ms)
    after
      silence_ms -> :ok
    end
  end

  defp spawn_session(run_id, opts) do
    :telemetry.span(
      [:gf, :session, :spawn],
      %{run_id: run_id},
      fn ->
        spec = {SessionGenServer, [{:run_id, run_id} | opts]}

        case DynamicSupervisor.start_child(@supervisor, spec) do
          {:ok, pid} ->
            {{:ok, pid}, %{run_id: run_id, pid_str: inspect(pid), reused: false}}

          {:error, {:already_started, pid}} ->
            {{:ok, pid}, %{run_id: run_id, pid_str: inspect(pid), reused: true}}

          {:error, reason} ->
            {{:error, reason}, %{run_id: run_id, error: inspect(reason)}}
        end
      end
    )
  end
end
