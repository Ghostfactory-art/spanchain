defmodule SpanChain.Ingestion.SessionSupervisor do
  @moduledoc """
  DynamicSupervisor wrapper — race-safe spawn SessionGenServer per run_id.

  ## Crash recovery (GF-775)

  SGS je `restart: :temporary` → crash NEauto-restartuje. `ensure_session/1` na
  prázdný Registry zjistí přes DB jestli `run_id` existuje:
  - **nový run** → spawn s epoch 0, prev_hash nil (defaulty).
  - **restart** (run v DB) → drain in-flight staré epochy (PubSub `epoch_flush:`),
    pak spawn s `epoch_id+1` a `prev_hash` = poslední commitnutý hash (zachová
    GF-666 cross-epoch kontinuitu → `verify_ledger/1` zůstane `{:ok, _}`).

  Repo read žije VÝHRADNĚ zde — SGS zůstává Repo-free (GF-751).
  """

  import Ecto.Query, only: [from: 2]

  alias SpanChain.{Ledger, Repo}
  alias SpanChain.Ingestion.SessionGenServer

  require Logger

  @supervisor __MODULE__
  @registry SpanChain.Ingestion.SessionRegistry

  @doc "Child spec pro Supervisor v Application."
  def child_spec(_opts) do
    DynamicSupervisor.child_spec(name: @supervisor, strategy: :one_for_one)
  end

  @doc """
  Vrátí pid SessionGenServeru pro `run_id`. Pokud session neexistuje,
  spawnne ji. Race condition mezi dvěma současnými calls je explicitně
  ošetřena přes `{:error, {:already_started, pid}}`.

  Volitelné `opts`:
    * `:eval_id` (GF-706) — pasivní associace `run` ↔ `eval` při SGS init.
      Spawn-time-only: opts se aplikují jen pokud se SGS skutečně spawne
      (existující SGS pro stejný run_id ignoruje opts — eval_id už byl
      perzistován v jeho init).
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

  # GF-775: Registry prázdný → buď nový run, nebo restart (run už je v DB).
  # Recovery: drain staré epochy, pak spawn s novou epochou + carried prev_hash.
  defp recover_or_spawn(run_id, opts) do
    case fetch_last_epoch(run_id) do
      nil ->
        # Nový run — žádné DB záznamy. Defaulty epoch 0 / prev_hash nil.
        spawn_session(run_id, opts)

      last_epoch ->
        # Restart. Počkej až in-flight spany staré epochy commitnou, pak přečti
        # skutečný poslední hash (Postgres read-after-write po commitu, GF-704).
        await_epoch_drain(run_id, last_epoch)
        prev_hash = fetch_last_hash(run_id)
        spawn_session(run_id, [epoch_id: last_epoch + 1, prev_hash: prev_hash] ++ opts)
    end
  end

  # Repo reads — VÝHRADNĚ zde, nikdy v SessionGenServer (GF-751).
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

  # Čeká na flush in-flight batchů staré epochy. `{:epoch_flushed}` broadcastuje
  # Pipeline.handle_batch po commitu. Symetrický un/subscribe (unsubscribe VŽDY voláno).
  #
  # GF-782: "drain until silence" — po PRVNÍM flush staré epochy drainuj dokud nepřijde
  # `silence_ms` ticha. Burst > batch_size (50) = multiple batche in-flight; návrat po
  # PRVNÍM flush (předchozí chování) nechal `fetch_last_hash` číst stale pozici → nová
  # epocha se stale prev_hash → `verify_ledger` {:error, :chain_broken} (GF-666 regrese).
  #
  # Cold-start guard NEpotřeba: `await_epoch_drain/2` je voláno VÝHRADNĚ z `last_epoch`
  # větve `recover_or_spawn/2`; `nil` větev (nový run) jde přímo na `spawn_session/2`.
  defp await_epoch_drain(run_id, old_epoch) do
    # GF-786: epoch_drain_timeout NENÍ config key — derivováno z aktuálního batch_timeout, takže
    # se synchronizuje s `BATCH_FLUSH_TIMEOUT_MS` runtime overridem (GF-777). 10× + 200ms buffer
    # zachová GF-780 invariant (drain > batch_timeout) i prod hodnotu 1_200ms (100*10+200; test
    # 50*10+200=700ms). Timeout path: pokud Broadway commitne VŠE PŘED `subscribe` (rychlý
    # Postgres), `receive` nedostane zprávu a vrátí :ok po timeout_ms → `fetch_last_hash` čte
    # správná committed data (správné chování, jen latence; loguje warning níže).
    batch_timeout = Application.get_env(:span_chain, :broadway_batch_timeout_ms, 100)
    timeout_ms = batch_timeout * 10 + 200

    # GF-782: silence_ms MUSÍ být > batch_timeout (100ms prod po GF-777) — default 200ms = 2×.
    silence_ms = Application.get_env(:span_chain, :epoch_drain_silence_ms, 200)
    topic = "epoch_flush:#{run_id}"
    :ok = Phoenix.PubSub.subscribe(SpanChain.PubSub, topic)

    receive do
      {:epoch_flushed, ^run_id, ^old_epoch} ->
        drain_until_silence(run_id, old_epoch, silence_ms)
    after
      timeout_ms ->
        Logger.warning(
          "[SessionSupervisor] epoch drain timeout pro run_id=#{run_id}, epoch=#{old_epoch} — " <>
            "předpokládáme missed broadcast, data by měla být committed"
        )

        :ok
    end

    Phoenix.PubSub.unsubscribe(SpanChain.PubSub, topic)
    :ok
  end

  # Drainuje dokud nepřijde `silence_ms` ticha po POSLEDNÍ zprávě pro old_epoch. Každý
  # další flush staré epochy resetuje silence okno; zprávy pro jiné epochy / run_ids se
  # selektivním receivem ignorují (zůstanou v mailboxu — flush jiné session).
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
