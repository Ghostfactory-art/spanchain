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
    do_sweep()
    if state.interval != :infinity, do: schedule_sweep(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:sweep_now, _from, state) do
    result = do_sweep()
    {:reply, result, state}
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
