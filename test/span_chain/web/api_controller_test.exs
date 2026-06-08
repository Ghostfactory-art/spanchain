defmodule SpanChain.Web.ApiControllerTest do
  @moduledoc "GF-789: JSON API endpoints + CORS (port 4001, /api scope)."

  use SpanChain.DataCase, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias SpanChain.{Cassette, Cassettes, Eval, Ledger, Repo, Run}
  alias SpanChain.Cassettes.ReplayJob

  @endpoint SpanChain.Web.Endpoint
  @token "test-secret"

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer #{@token}")

  # Seed a run + valid 2-span hash chain (1 ok, 1 error) directly into the sandbox.
  # `eval_id` optionally associates the run with an eval (GF-793 compare tests).
  defp seed_run(run_id, eval_id \\ nil) do
    Repo.insert!(%Run{
      run_id: run_id,
      eval_id: eval_id,
      status: "running",
      started_at: ~U[2026-05-15 10:00:00Z]
    })

    specs = [
      %{
        "span_id" => "s0",
        "name" => "root",
        "started_at" => "2026-05-15T10:00:00Z",
        "ended_at" => "2026-05-15T10:00:02Z",
        "status" => "ok"
      },
      %{
        "span_id" => "s1",
        "name" => "child",
        "started_at" => "2026-05-15T10:00:01Z",
        "ended_at" => "2026-05-15T10:00:02Z",
        "status" => "error"
      }
    ]

    {entries, _} =
      specs
      |> Enum.with_index()
      |> Enum.reduce({[], nil}, fn {spec, i}, {acc, prev} ->
        entry = Ledger.build_entry(run_id, 0, i, prev, "span", spec, nil)
        {acc ++ [entry], entry.hash}
      end)

    {2, _} = Ledger.insert_batch(entries)
    :ok
  end

  describe "CORS + auth" do
    test "OPTIONS /api/runs with allowed Origin → 200 + Access-Control-Allow-Origin" do
      conn =
        build_conn()
        |> put_req_header("origin", "http://localhost:5173")
        |> put_req_header("access-control-request-method", "GET")
        |> options("/api/runs")

      assert conn.status == 200
      assert get_resp_header(conn, "access-control-allow-origin") == ["http://localhost:5173"]
    end

    test "GET /api/runs without Bearer token → 401" do
      conn = get(build_conn(), "/api/runs")
      assert conn.status == 401
    end
  end

  describe "rate limiting (GF-851)" do
    setup do
      Application.put_env(:span_chain, :rate_limit_enabled, true)
      Application.put_env(:span_chain, :rate_limit_count, 2)
      # Separate buckets for /api (per token) and /trail (per IP) — clean between tests.
      PlugAttack.Storage.Ets.clean(SpanChain.Web.RateLimiter.Api)
      PlugAttack.Storage.Ets.clean(SpanChain.Web.RateLimiter.Trail)

      on_exit(fn ->
        Application.put_env(:span_chain, :rate_limit_enabled, false)
        Application.put_env(:span_chain, :rate_limit_count, 1_000)
      end)

      :ok
    end

    test "/api per token — 3rd request over the limit → 429 + Retry-After" do
      assert build_conn() |> authed() |> get("/api/runs") |> Map.fetch!(:status) == 200
      assert build_conn() |> authed() |> get("/api/runs") |> Map.fetch!(:status) == 200

      conn = build_conn() |> authed() |> get("/api/runs")
      assert conn.status == 429
      assert {:ok, %{"error" => "rate_limit_exceeded"}} = Jason.decode(conn.resp_body)
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) >= 1
    end

    # The public /trail (no token) throttles per client IP via x-forwarded-for (behind Caddy).
    test "/trail per IP (x-forwarded-for) — 3rd request over the limit → 429" do
      trail = fn ->
        build_conn()
        |> put_req_header("x-forwarded-for", "203.0.113.7")
        |> get("/trail")
      end

      assert trail.().status == 200
      assert trail.().status == 200
      assert trail.().status == 429
    end

    # Separate ETS tables: an exhausted /api bucket must not throttle /trail (and vice versa).
    test "/api and /trail buckets are independent" do
      assert build_conn() |> authed() |> get("/api/runs") |> Map.fetch!(:status) == 200
      assert build_conn() |> authed() |> get("/api/runs") |> Map.fetch!(:status) == 200
      assert build_conn() |> authed() |> get("/api/runs") |> Map.fetch!(:status) == 429

      # The /trail bucket is untouched → it passes.
      conn = build_conn() |> put_req_header("x-forwarded-for", "198.51.100.9") |> get("/trail")
      assert conn.status == 200
    end
  end

  describe "runs" do
    test "GET /api/runs → runs + total, no payload key, native counts" do
      seed_run("api-run-1")

      body = build_conn() |> authed() |> get("/api/runs") |> json_response(200)

      assert is_list(body["runs"])
      assert is_integer(body["total"]) and body["total"] >= 1
      refute Enum.any?(body["runs"], &Map.has_key?(&1, "payload"))

      run = Enum.find(body["runs"], &(&1["run_id"] == "api-run-1"))
      assert run["span_count"] == 2
      assert run["error_count"] == 1
    end

    test "GET /api/runs/:run_id → spans skeleton, non-nil started_at, no payload" do
      seed_run("api-run-2")

      body = build_conn() |> authed() |> get("/api/runs/api-run-2") |> json_response(200)

      assert body["run"]["run_id"] == "api-run-2"
      assert length(body["spans"]) == 2
      assert Enum.all?(body["spans"], &(&1["started_at"] != nil))
      # GF-793: the span_id projection is present in every span (React builds the tree).
      assert Enum.all?(body["spans"], &(&1["span_id"] != nil))
      assert Enum.sort(Enum.map(body["spans"], & &1["span_id"])) == ["s0", "s1"]
      refute Enum.any?(body["spans"], &Map.has_key?(&1, "payload"))
    end

    test "GET /api/runs/:run_id unknown → 404" do
      conn = build_conn() |> authed() |> get("/api/runs/does-not-exist")
      assert conn.status == 404
    end

    test "GET /api/runs/:run_id from a cancelled replay → replay_job status cancelled (GF-828)" do
      seed_run("api-run-cancelled")

      Repo.insert!(%ReplayJob{
        cassette_id: "cas-828",
        new_run_id: "api-run-cancelled",
        status: "cancelled"
      })

      body = build_conn() |> authed() |> get("/api/runs/api-run-cancelled") |> json_response(200)

      assert body["replay_job"] == %{"status" => "cancelled"}
    end

    test "GET /api/runs/:run_id from a failed replay → replay_job status failed (GF-831)" do
      seed_run("api-run-failed")

      Repo.insert!(%ReplayJob{
        cassette_id: "cas-831",
        new_run_id: "api-run-failed",
        status: "failed"
      })

      body = build_conn() |> authed() |> get("/api/runs/api-run-failed") |> json_response(200)

      assert body["replay_job"] == %{"status" => "failed"}
    end

    test "GET /api/runs/:run_id for a normal run → replay_job null (GF-828)" do
      seed_run("api-run-normal")

      body = build_conn() |> authed() |> get("/api/runs/api-run-normal") |> json_response(200)

      assert body["replay_job"] == nil
    end

    test "POST /api/cassettes/:id/replay → 409 on duplicate new_run_id (GF-832)" do
      Repo.insert!(%Cassette{
        cassette_id: "cas-832",
        run_id: "run-832",
        snapshot: [],
        recorded_at: ~U[2026-05-15 10:00:00.000000Z]
      })

      Repo.insert!(%ReplayJob{cassette_id: "cas-832", new_run_id: "dup-832", status: "running"})

      conn =
        build_conn()
        |> authed()
        |> post("/api/cassettes/cas-832/replay", %{new_run_id: "dup-832"})

      assert json_response(conn, 409)["error"] == "new_run_id_already_exists"
    end

    test "GET /api/runs/:run_id/spans/:id → full payload present" do
      seed_run("api-run-3")
      row = Repo.one(from(l in Ledger, where: l.run_id == "api-run-3" and l.seq == 0))

      body =
        build_conn()
        |> authed()
        |> get("/api/runs/api-run-3/spans/#{row.id}")
        |> json_response(200)

      assert Map.has_key?(body, "payload")
      assert body["payload"]["span_id"] == "s0"
      assert body["status"] == "ok"
    end

    test "GET /api/runs/:run_id/spans/:id with non-integer id → 400" do
      conn = build_conn() |> authed() |> get("/api/runs/api-run-3/spans/not-an-int")
      assert conn.status == 400
    end

    test "GET /api/runs/:run_id/verify → verified true + span_count" do
      seed_run("api-run-4")

      body = build_conn() |> authed() |> get("/api/runs/api-run-4/verify") |> json_response(200)

      assert body["verified"] == true
      assert body["span_count"] == 2
    end
  end

  describe "evals + cassettes" do
    test "GET /api/evals → list shape" do
      body = build_conn() |> authed() |> get("/api/evals") |> json_response(200)
      assert is_list(body["evals"])
      assert is_integer(body["total"])
    end

    test "GET /api/evals/:id unknown → 404" do
      conn = build_conn() |> authed() |> get("/api/evals/does-not-exist")
      assert conn.status == 404
    end

    test "GET /api/cassettes → list shape (no snapshot)" do
      body = build_conn() |> authed() |> get("/api/cassettes") |> json_response(200)
      assert is_list(body["cassettes"])
      assert is_integer(body["total"])
      refute Enum.any?(body["cassettes"], &Map.has_key?(&1, "snapshot"))
    end
  end

  describe "async replay (GF-798)" do
    test "POST /api/cassettes/:id/replay → 202 + job_id; job completes; poll returns result" do
      seed_run("replay-src-1")
      {:ok, _} = Cassettes.record("replay-src-1", cassette_id: "cas-async-1")

      body =
        build_conn()
        |> authed()
        |> post("/api/cassettes/cas-async-1/replay")
        |> json_response(202)

      assert is_binary(body["job_id"])
      assert body["status"] == "running"

      job = await_job(body["job_id"])
      assert job.status == "completed"

      poll =
        build_conn()
        |> authed()
        |> get("/api/cassettes/replay_jobs/#{body["job_id"]}")
        |> json_response(200)

      assert poll["id"] == body["job_id"]
      assert poll["status"] == "completed"
      assert poll["result"]["hash_valid"] == true
      assert poll["result"]["span_count"] == 2
    end

    test "POST /api/cassettes/:id/replay unknown cassette → 404 cassette_not_found" do
      conn = build_conn() |> authed() |> post("/api/cassettes/does-not-exist/replay")
      assert conn.status == 404
      assert json_response(conn, 404)["error"] == "cassette_not_found"
    end

    test "GET /api/cassettes/replay_jobs/:id unknown → 404" do
      conn =
        build_conn() |> authed() |> get("/api/cassettes/replay_jobs/#{Ecto.UUID.generate()}")

      assert conn.status == 404
    end

    test "DELETE /api/cassettes/replay_jobs/:id running → 200 cancelled (GF-823)" do
      job =
        Repo.insert!(%ReplayJob{
          cassette_id: "cas-del-1",
          new_run_id: "run-del-1",
          status: "running"
        })

      conn = build_conn() |> authed() |> delete("/api/cassettes/replay_jobs/#{job.id}")
      assert json_response(conn, 200)["status"] == "cancelled"
      assert Repo.get!(ReplayJob, job.id).status == "cancelled"
    end

    test "DELETE /api/cassettes/replay_jobs/:id unknown → 404 (GF-823)" do
      conn =
        build_conn() |> authed() |> delete("/api/cassettes/replay_jobs/#{Ecto.UUID.generate()}")

      assert conn.status == 404
    end

    test "DELETE /api/cassettes/replay_jobs/:id completed → 409 already_terminal (GF-823)" do
      job =
        Repo.insert!(%ReplayJob{
          cassette_id: "cas-del-2",
          new_run_id: "run-del-2",
          status: "completed"
        })

      conn = build_conn() |> authed() |> delete("/api/cassettes/replay_jobs/#{job.id}")
      assert conn.status == 409
      assert json_response(conn, 409)["error"] == "already_terminal"
    end
  end

  describe "run_id validation (GF-850)" do
    test "POST /api/cassettes/:id/replay with invalid new_run_id → 400, no job persisted" do
      Repo.insert!(%Cassette{
        cassette_id: "cas-850",
        run_id: "run-850",
        snapshot: [],
        recorded_at: ~U[2026-05-15 10:00:00.000000Z]
      })

      conn =
        build_conn()
        |> authed()
        |> post("/api/cassettes/cas-850/replay", %{new_run_id: String.duplicate("a", 129)})

      assert json_response(conn, 400)["error"] == "invalid_run_id"
      # The guard runs BEFORE enqueue → no replay_job was created.
      assert Repo.aggregate(from(j in ReplayJob, where: j.cassette_id == "cas-850"), :count) == 0
    end

    test "POST /api/cassettes/:id/replay with valid new_run_id → 202 (existing behavior intact)" do
      seed_run("replay-src-850")
      {:ok, _} = Cassettes.record("replay-src-850", cassette_id: "cas-850-ok")

      body =
        build_conn()
        |> authed()
        |> post("/api/cassettes/cas-850-ok/replay", %{new_run_id: "valid-replay-850"})
        |> json_response(202)

      assert is_binary(body["job_id"])
      job = await_job(body["job_id"])
      assert job.status == "completed"
      assert job.new_run_id == "valid-replay-850"
    end

    test "GET /api/runs/:run_id/verify with oversized run_id → 400 (plug)" do
      conn =
        build_conn() |> authed() |> get("/api/runs/#{String.duplicate("a", 129)}/verify")

      assert json_response(conn, 400)["error"] == "invalid_run_id"
    end

    test "GET /api/runs/:run_id with malformed run_id → 400 (plug)" do
      conn = build_conn() |> authed() |> get("/api/runs/#{String.duplicate("a", 129)}")
      assert json_response(conn, 400)["error"] == "invalid_run_id"
    end
  end

  # Bounded wait for the async replay task to flip the job out of "running"
  # (receive/after — BEAM idiom, not Process.sleep).
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

  describe "eval compare (GF-793)" do
    setup do
      Repo.insert!(%Eval{eval_id: "ev-cmp", name: "cmp", status: "running"})
      seed_run("cmp-a", "ev-cmp")
      seed_run("cmp-b", "ev-cmp")
      :ok
    end

    test "GET /api/evals/:id/compare with valid runs → 200 + summary + differences" do
      body =
        build_conn()
        |> authed()
        |> get("/api/evals/ev-cmp/compare?run_a=cmp-a&run_b=cmp-b")
        |> json_response(200)

      assert body["eval_id"] == "ev-cmp"
      assert body["run_a"] == "cmp-a"
      assert body["run_b"] == "cmp-b"
      assert is_map(body["summary"])
      assert is_list(body["differences"])
    end

    test "GET /api/evals/:id/compare without params → 400" do
      conn = build_conn() |> authed() |> get("/api/evals/ev-cmp/compare")
      assert conn.status == 400
    end

    test "GET /api/evals/:id/compare with only run_a → 400" do
      conn = build_conn() |> authed() |> get("/api/evals/ev-cmp/compare?run_a=cmp-a")
      assert conn.status == 400
    end

    test "GET /api/evals/nonexistent/compare → 404" do
      conn =
        build_conn()
        |> authed()
        |> get("/api/evals/nonexistent/compare?run_a=cmp-a&run_b=cmp-b")

      assert conn.status == 404
    end

    test "GET /api/evals/:id/compare with runs from different evals → 422" do
      Repo.insert!(%Eval{eval_id: "ev-other", name: "other", status: "running"})
      seed_run("cmp-c", "ev-other")

      conn =
        build_conn()
        |> authed()
        |> get("/api/evals/ev-cmp/compare?run_a=cmp-a&run_b=cmp-c")

      assert conn.status == 422
    end
  end
end
