defmodule SpanChain.Cassettes.ReplayJobSweeper do
  @moduledoc "Periodic sweeper: marks stale running replay_jobs as failed (`:EXIT`-safe, GF-807) and deletes completed/failed jobs past the retention window (GF-805)."

  use GenServer
  import Ecto.Query
  require Logger

  alias SpanChain.Repo
  alias SpanChain.Cassettes.ReplayJob

  # Defaults — overridable via Application.get_env (test seams).
  @stuck_interval_ms 5 * 60 * 1_000
  @retention_interval_ms 24 * 60 * 60 * 1_000
  @stale_threshold_s 10 * 60
  @retention_days 30

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state) do
    Process.send_after(self(), :sweep_stuck, stuck_interval())
    Process.send_after(self(), :sweep_retention, retention_interval())
    {:ok, state}
  end

  @impl true
  def handle_info(:sweep_stuck, state) do
    sweep_stuck_jobs()
    Process.send_after(self(), :sweep_stuck, stuck_interval())
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep_retention, state) do
    sweep_retention()
    Process.send_after(self(), :sweep_retention, retention_interval())
    {:noreply, state}
  end

  # Public for testing without mounting the GenServer.
  def sweep_stuck_jobs do
    cutoff = cutoff_naive(-stale_threshold_s())

    {count, _} =
      from(j in ReplayJob,
        where: j.status == "running" and j.inserted_at < ^cutoff
      )
      |> Repo.update_all(set: [status: "failed", result: %{"error" => "timeout_or_killed"}])

    if count > 0, do: Logger.info("[ReplayJobSweeper] #{count} stale job(s) → failed")
    count
  end

  def sweep_retention do
    cutoff = cutoff_naive(-@retention_days * 86_400)

    {count, _} =
      from(j in ReplayJob,
        where: j.status in ["completed", "failed"] and j.inserted_at < ^cutoff
      )
      |> Repo.delete_all()

    if count > 0, do: Logger.info("[ReplayJobSweeper] deleted #{count} expired job(s)")
    count
  end

  # --- private helpers ---

  defp cutoff_naive(offset_seconds) do
    NaiveDateTime.utc_now() |> NaiveDateTime.add(offset_seconds, :second)
  end

  defp stuck_interval,
    do: Application.get_env(:span_chain, :stuck_sweep_interval_ms, @stuck_interval_ms)

  defp retention_interval,
    do: Application.get_env(:span_chain, :retention_sweep_interval_ms, @retention_interval_ms)

  defp stale_threshold_s,
    do: Application.get_env(:span_chain, :stuck_stale_threshold_s, @stale_threshold_s)
end
