defmodule GfExperiment.Repo.Migrations.CreateReplayJobs do
  @moduledoc """
  GF-798: async replay jobs. `POST /api/cassettes/:id/replay` enqueues a row here
  (status "running"), a Task.Supervisor task runs the replay and updates the row to
  "completed"/"failed" with the result; the frontend polls
  `GET /api/cassettes/replay_jobs/:id`. `result` is jsonb (the Replayer result map or
  an error map).
  """
  use Ecto.Migration

  def change do
    create table(:replay_jobs, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :cassette_id, :string, null: false
      add :new_run_id, :string, null: false
      add :status, :string, null: false, default: "running"
      add :result, :map
      timestamps()
    end

    create index(:replay_jobs, [:cassette_id])
  end
end
