defmodule SpanChain.CassettesTest do
  @moduledoc """
  Context tests pro `SpanChain.Cassettes` (GF-712). Insertujeme spans
  přes Pipeline (BufferProducer → Broadway), čekáme na `:gf, :ledger,
  :batch_insert, :stop` telemetry (filter na run_id) než ověříme cassette.

  Replay test: subscribuje na `"run:replay-..."` topic PŘED `replay/1`
  a verifikuje hash chain + diff přes Comparator.
  """

  use SpanChain.DataCase, async: false

  alias SpanChain.{Cassette, Cassettes, Ledger, Repo}
  alias SpanChain.Cassettes.ReplayJob
  alias SpanChain.Ingestion.{SessionGenServer, SessionSupervisor}

  defp fresh_run_id(prefix \\ "cas"),
    do: "#{prefix}-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp fresh_cassette_id,
    do: "cassette-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp attach_flush_handler(run_id) do
    test_pid = self()
    ref = make_ref()
    handler_id = "cas-flush-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      [:gf, :ledger, :batch_insert, :stop],
      fn _e, _m, meta, _ ->
        if run_id in Map.get(meta, :run_ids, []), do: send(test_pid, {:flushed, ref})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  defp ingest_and_wait(run_id, spans) do
    ref = attach_flush_handler(run_id)
    {:ok, _pid} = SessionSupervisor.ensure_session(run_id)
    {:ok, _n} = SessionGenServer.ingest_spans(run_id, spans)
    assert_receive {:flushed, ^ref}, 2_000
    :ok
  end

  defp span(name, started_iso, ended_iso, opts \\ []) do
    base = %{
      "span_id" =>
        Keyword.get(
          opts,
          :span_id,
          "sp-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
        ),
      "name" => name,
      "started_at" => started_iso,
      "ended_at" => ended_iso,
      "attributes" => %{}
    }

    case Keyword.get(opts, :parent_span_id) do
      nil -> base
      pid -> Map.put(base, "parent_span_id", pid)
    end
  end

  describe "record/2" do
    test "captures payloads ordered by seq into snapshot" do
      run_id = fresh_run_id()
      cassette_id = fresh_cassette_id()

      ingest_and_wait(run_id, [
        span("root", "2026-05-17T10:00:00.000Z", "2026-05-17T10:00:01.000Z", span_id: "r1"),
        span("child", "2026-05-17T10:00:00.100Z", "2026-05-17T10:00:00.900Z",
          span_id: "c1",
          parent_span_id: "r1"
        )
      ])

      assert {:ok, %Cassette{} = c} =
               Cassettes.record(run_id, cassette_id: cassette_id, name: "demo")

      assert c.cassette_id == cassette_id
      assert c.run_id == run_id
      assert c.name == "demo"
      assert length(c.snapshot) == 2
      assert Enum.at(c.snapshot, 0)["name"] == "root"
      assert Enum.at(c.snapshot, 1)["name"] == "child"
      assert %DateTime{} = c.recorded_at
    end

    test "returns :run_not_found when no ledger rows exist for run_id" do
      assert {:error, :run_not_found} =
               Cassettes.record("missing-" <> fresh_run_id(), cassette_id: fresh_cassette_id())
    end

    test "returns :missing_cassette_id when cassette_id is blank" do
      assert {:error, :missing_cassette_id} = Cassettes.record(fresh_run_id(), cassette_id: "")
    end
  end

  describe "get/1 + list/0" do
    test "get returns cassette or :not_found" do
      run_id = fresh_run_id()
      cid = fresh_cassette_id()

      ingest_and_wait(run_id, [span("only", "2026-05-17T10:00:00Z", "2026-05-17T10:00:01Z")])

      {:ok, _} = Cassettes.record(run_id, cassette_id: cid)

      assert {:ok, %Cassette{cassette_id: ^cid}} = Cassettes.get(cid)
      assert {:error, :not_found} = Cassettes.get("nope-" <> cid)
    end
  end

  describe "replay/2" do
    test "identical replay produces empty diff and valid hash chain" do
      run_id = fresh_run_id()
      cid = fresh_cassette_id()

      ingest_and_wait(run_id, [
        span("root", "2026-05-17T10:00:00.000Z", "2026-05-17T10:00:01.000Z", span_id: "r1"),
        span("child", "2026-05-17T10:00:00.100Z", "2026-05-17T10:00:00.900Z",
          span_id: "c1",
          parent_span_id: "r1"
        )
      ])

      {:ok, _} = Cassettes.record(run_id, cassette_id: cid)

      assert {:ok, %{run_id: replayed, span_count: 2, hash_valid: true, diff: []}} =
               Cassettes.replay(cid)

      assert {:ok, 2} = Ledger.verify_ledger(replayed)
      assert Repo.aggregate(Cassette, :count, :cassette_id) >= 1
    end
  end

  describe "enqueue_replay/2 (GF-798)" do
    test "enqueues a running job, runs async, and marks it completed" do
      run_id = fresh_run_id()
      cid = fresh_cassette_id()

      ingest_and_wait(run_id, [
        span("root", "2026-05-17T10:00:00.000Z", "2026-05-17T10:00:01.000Z", span_id: "r1"),
        span("child", "2026-05-17T10:00:00.100Z", "2026-05-17T10:00:00.900Z",
          span_id: "c1",
          parent_span_id: "r1"
        )
      ])

      {:ok, _} = Cassettes.record(run_id, cassette_id: cid)

      # We control new_run_id, so subscribe to its post-commit broadcast (fires from a
      # different pid than the Replayer task, so the task's after-block unsubscribe
      # doesn't touch this subscription).
      new_run_id = fresh_run_id("replay")
      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{new_run_id}")

      assert {:ok, %ReplayJob{} = job} = Cassettes.enqueue_replay(cid, new_run_id)
      assert job.status == "running"
      assert is_binary(job.id)

      assert_receive {:spans_flushed, ^new_run_id}, 5_000
      job = await_job(job.id)

      assert job.status == "completed"
      assert job.new_run_id == new_run_id
      assert job.result["hash_valid"] == true
      assert job.result["span_count"] == 2
    end

    test "returns :not_found for an unknown cassette (no job inserted)" do
      assert {:error, :not_found} =
               Cassettes.enqueue_replay("nope-" <> fresh_cassette_id(), fresh_run_id("replay"))
    end
  end

  # Bounded wait for the async task to flip the job out of "running". Uses receive/after
  # (BEAM idiom, not Process.sleep): after {:spans_flushed} the task only does verify +
  # compare + one DB update, so this resolves in a couple of polls.
  defp await_job(job_id, deadline_ms \\ 8_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    await_job_loop(job_id, deadline)
  end

  defp await_job_loop(job_id, deadline) do
    job = Repo.get(ReplayJob, job_id)

    cond do
      job && job.status != "running" ->
        job

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("replay job #{job_id} still running past deadline")

      true ->
        receive do
        after
          25 -> :ok
        end

        await_job_loop(job_id, deadline)
    end
  end

  describe "cancel_replay_job/1 (GF-823)" do
    test "running job → {:ok, _} with status cancelled" do
      job = insert_replay_job("running")
      assert {:ok, cancelled} = Cassettes.cancel_replay_job(job.id)
      assert cancelled.status == "cancelled"
      assert Repo.get!(ReplayJob, job.id).status == "cancelled"
    end

    test "completed job → {:error, :already_terminal} (left unchanged)" do
      job = insert_replay_job("completed")
      assert {:error, :already_terminal} = Cassettes.cancel_replay_job(job.id)
      assert Repo.get!(ReplayJob, job.id).status == "completed"
    end

    test "unknown or malformed id → {:error, :not_found}" do
      assert {:error, :not_found} = Cassettes.cancel_replay_job(Ecto.UUID.generate())
      assert {:error, :not_found} = Cassettes.cancel_replay_job("not-a-uuid")
    end
  end

  describe "run_replay_job/1 ghost-task guard (GF-827)" do
    test "a terminal write after cancel does NOT overwrite cancelled" do
      run_id = fresh_run_id()
      cid = fresh_cassette_id()

      ingest_and_wait(run_id, [
        span("root", "2026-05-17T10:00:00.000Z", "2026-05-17T10:00:01.000Z", span_id: "r1"),
        span("child", "2026-05-17T10:00:00.100Z", "2026-05-17T10:00:00.900Z",
          span_id: "c1",
          parent_span_id: "r1"
        )
      ])

      {:ok, _} = Cassettes.record(run_id, cassette_id: cid)

      # A real, replayable job — but cancelled BEFORE the (stale) task body runs.
      job =
        Repo.insert!(%ReplayJob{
          cassette_id: cid,
          new_run_id: fresh_run_id("replay"),
          status: "running"
        })

      assert {:ok, _} = Cassettes.cancel_replay_job(job.id)
      assert Repo.get!(ReplayJob, job.id).status == "cancelled"

      # Ghost Task: runs to completion with its stale "running" struct. replay/2 succeeds
      # (real cassette), so without the atomic guard it would write "completed". The
      # WHERE status = 'running' clause matches 0 rows → the write is a no-op.
      Cassettes.run_replay_job(job)

      assert Repo.get!(ReplayJob, job.id).status == "cancelled"
    end

    test "without a cancel, a running job is marked completed (happy path intact)" do
      run_id = fresh_run_id()
      cid = fresh_cassette_id()

      ingest_and_wait(run_id, [
        span("root", "2026-05-17T10:00:00.000Z", "2026-05-17T10:00:01.000Z", span_id: "r1")
      ])

      {:ok, _} = Cassettes.record(run_id, cassette_id: cid)

      job =
        Repo.insert!(%ReplayJob{
          cassette_id: cid,
          new_run_id: fresh_run_id("replay"),
          status: "running"
        })

      Cassettes.run_replay_job(job)

      reloaded = Repo.get!(ReplayJob, job.id)
      assert reloaded.status == "completed"
      assert reloaded.result["hash_valid"] == true
    end

    test "an unknown cassette fails the running job (and the guard still applies)" do
      job =
        Repo.insert!(%ReplayJob{
          cassette_id: "nope-" <> fresh_cassette_id(),
          new_run_id: fresh_run_id("replay"),
          status: "running"
        })

      Cassettes.run_replay_job(job)

      reloaded = Repo.get!(ReplayJob, job.id)
      assert reloaded.status == "failed"
      assert is_map(reloaded.result)
    end
  end

  describe "get_replay_job_for_run/1 (GF-828)" do
    test "a run produced by a replay job → %{status: ...}" do
      job = insert_replay_job("cancelled")
      assert %{status: "cancelled"} = Cassettes.get_replay_job_for_run(job.new_run_id)
    end

    test "a run with no replay job → nil" do
      assert Cassettes.get_replay_job_for_run(fresh_run_id("no-replay")) == nil
    end

    test "nil / non-binary run_id → nil (guard, no crash)" do
      assert Cassettes.get_replay_job_for_run(nil) == nil
      assert Cassettes.get_replay_job_for_run(123) == nil
    end
  end

  describe "new_run_id unique constraint (GF-832)" do
    test "a second replay_job with the same new_run_id is rejected" do
      dup = fresh_run_id("replay")
      attrs = %{cassette_id: fresh_cassette_id(), new_run_id: dup, status: "running"}

      assert {:ok, _} = Repo.insert(ReplayJob.changeset(%ReplayJob{}, attrs))

      assert {:error, changeset} =
               Repo.insert(
                 ReplayJob.changeset(%ReplayJob{}, %{attrs | cassette_id: fresh_cassette_id()})
               )

      assert {"has already been taken", _} = changeset.errors[:new_run_id]
    end
  end

  defp insert_replay_job(status) do
    Repo.insert!(%ReplayJob{
      cassette_id: fresh_cassette_id(),
      new_run_id: fresh_run_id("replay"),
      status: status
    })
  end
end
