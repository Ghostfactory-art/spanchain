defmodule SpanChain.Cassettes.ReplayJobSweeperTest do
  @moduledoc """
  GF-807/805: sweep_stuck_jobs/0 (stale running → failed) + sweep_retention/0
  (old terminal jobs deleted). Calls the public sweep fns directly — no GenServer
  mount; config seams (config/test.exs) set stuck_stale_threshold_s: 1.
  """
  use SpanChain.DataCase, async: true

  alias SpanChain.Repo
  alias SpanChain.Cassettes.ReplayJob
  alias SpanChain.Cassettes.ReplayJobSweeper

  @old ~N[2020-01-01 00:00:00]

  defp insert_job(status, inserted_at) do
    Repo.insert!(%ReplayJob{
      cassette_id: "cass-#{System.unique_integer([:positive])}",
      new_run_id: "run-#{System.unique_integer([:positive])}",
      status: status,
      result: nil,
      inserted_at: inserted_at,
      updated_at: inserted_at
    })
  end

  describe "sweep_stuck_jobs/0" do
    test "marks a stale running job as failed with the timeout error" do
      job = insert_job("running", @old)

      assert ReplayJobSweeper.sweep_stuck_jobs() >= 1

      reloaded = Repo.get!(ReplayJob, job.id)
      assert reloaded.status == "failed"
      assert reloaded.result == %{"error" => "timeout_or_killed"}
    end

    test "leaves a fresh running job untouched" do
      fresh = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      job = insert_job("running", fresh)

      ReplayJobSweeper.sweep_stuck_jobs()

      assert Repo.get!(ReplayJob, job.id).status == "running"
    end

    test "leaves a completed job untouched regardless of age" do
      job = insert_job("completed", @old)

      ReplayJobSweeper.sweep_stuck_jobs()

      assert Repo.get!(ReplayJob, job.id).status == "completed"
    end
  end

  describe "sweep_retention/0" do
    test "deletes an old completed job" do
      job = insert_job("completed", @old)

      assert ReplayJobSweeper.sweep_retention() >= 1
      assert Repo.get(ReplayJob, job.id) == nil
    end

    test "never deletes a running job, regardless of age" do
      job = insert_job("running", @old)

      ReplayJobSweeper.sweep_retention()

      assert Repo.get(ReplayJob, job.id) != nil
    end
  end
end
