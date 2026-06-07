defmodule GfExperiment.Repo.Migrations.AddUniqueIndexReplayJobsNewRunId do
  @moduledoc """
  GF-832: DB-level uniqueness on `replay_jobs.new_run_id`. The column is NOT NULL and
  carries a fresh run id per job, so a plain unique index is the full guarantee — the
  last line of defence behind `Cassettes.get_replay_job_for_run/1`'s ORDER BY ... LIMIT 1
  safety net. Additive + reversible (rolls back to `drop`).
  """
  use Ecto.Migration

  def change do
    # null: false → plain unique index sufficient; PostgreSQL NULL != NULL would require partial index
    create unique_index(:replay_jobs, [:new_run_id])
  end
end
