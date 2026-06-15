defmodule SpanChain.LedgerVerifier do
  @moduledoc """
  Periodic background job that runs verify_ledger/1 across all recent runs.
  On :chain_broken: emits [:span_chain, :ledger, :chain_broken] telemetry
  and Logger.error.

  Config seams (config.exs / test.exs):
    :verify_sweep_interval_ms  — interval between sweeps, or :infinity to disable auto-sweep
                                 (default: 300_000 = 5 min; set :infinity in test env)
    :verify_since_minutes      — lookback window for recent runs (default: 60)
  """
  use GenServer
  require Logger

  @default_interval_ms 300_000
  @default_since_minutes 60
  @max_runs_per_sweep 200

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Runs sweep synchronously — for tests without waiting for a timer."
  def sweep_now do
    GenServer.call(__MODULE__, :sweep_now)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    interval = Application.get_env(:span_chain, :verify_sweep_interval_ms, @default_interval_ms)
    # :infinity = GenServer starts normally but never schedules auto-sweep (test seam)
    if interval != :infinity, do: schedule_sweep(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:sweep, state) do
    # GF-1009: do_sweep/0 can block the loop 6–12 s (200 runs × 30–60 ms SHA-256 verify).
    # Run it off the GenServer loop. Fire-and-forget: at the prod interval (minutes) vs.
    # sweep duration (seconds) overlapping sweeps can't occur; if the interval were ever
    # dropped below the duration, a sweep_running? guard would be needed (out of scope).
    Task.start(fn -> do_sweep() end)
    if state.interval != :infinity, do: schedule_sweep(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:sweep_now, from, state) do
    # GF-1009: :async (prod default) runs do_sweep/0 in a Task so the loop stays responsive,
    # replying to the caller from the Task once the sweep finishes. :sync (test seam) keeps the
    # sweep in the GenServer process, which holds the allowed Ecto Sandbox checkout (a Task is a
    # new PID and would not inherit it).
    case Application.get_env(:span_chain, :sweep_call_mode, :async) do
      :sync ->
        {:reply, do_sweep(), state}

      :async ->
        # Trade-off: if the Task crashes before it replies the caller hangs forever (no reply-side
        # timeout). Acceptable for a fire-and-forget diagnostic sweep; full robustness would need
        # Task.Supervisor + monitoring (out of scope).
        Task.start(fn ->
          result = do_sweep()
          GenServer.reply(from, result)
        end)

        {:noreply, state}
    end
  end

  # --- Private ---

  defp schedule_sweep(interval) do
    Process.send_after(self(), :sweep, interval)
  end

  defp do_sweep do
    since_minutes =
      Application.get_env(:span_chain, :verify_since_minutes, @default_since_minutes)

    cutoff = DateTime.add(DateTime.utc_now(), -(since_minutes * 60), :second)

    run_ids = fetch_recent_run_ids(cutoff)

    results =
      Enum.map(run_ids, fn run_id ->
        case SpanChain.Ledger.verify_ledger(run_id) do
          {:ok, _count} ->
            :ok

          {:error, :chain_broken} ->
            Logger.error("[LedgerVerifier] chain_broken detected run_id=#{run_id}")

            :telemetry.execute(
              [:span_chain, :ledger, :chain_broken],
              %{count: 1},
              %{run_id: run_id}
            )

            {:error, :chain_broken, run_id}

          {:error, reason} ->
            Logger.warning(
              "[LedgerVerifier] unexpected verify error run_id=#{run_id} reason=#{inspect(reason)}"
            )

            {:error, reason, run_id}
        end
      end)

    broken = Enum.count(results, &match?({:error, :chain_broken, _}, &1))
    %{checked: length(run_ids), broken: broken}
  end

  defp fetch_recent_run_ids(cutoff) do
    import Ecto.Query

    SpanChain.Repo.all(
      from(r in SpanChain.Run,
        where: r.inserted_at >= ^cutoff,
        select: r.run_id,
        # guard: cap unbounded list; L3 chunking is GF-826 scope
        limit: @max_runs_per_sweep
      )
    )
  end
end
