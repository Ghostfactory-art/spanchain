defmodule SpanChain.Web.ApiController do
  @moduledoc """
  Read-only JSON API for the Span Chain UI (GF-789), under the `/api` scope on port 4001.

  OOM-safe principle: list and skeleton endpoints NEVER select `payload` or do
  JSONB extraction — only native columns (GF-669/GF-790). The full `payload` goes out only
  in `get_span/2` (single row, on-demand).
  """

  use Phoenix.Controller, formats: [:json]

  import Plug.Conn
  import Ecto.Query

  alias SpanChain.{Cassettes, Evals, Ledger, Repo}
  alias SpanChain.Ingestion.ValidationPlug

  # GF-850: validate the :run_id path param on read actions (the port-4001 :api has no ingest
  # ValidationPlug). Reuse the public valid_run_id?/1 — single-source regex contract (GF-774).
  plug(:validate_run_id when action in [:get_run, :get_span, :verify_run])

  # --------------------------------------------------------------------------
  # Runs
  # --------------------------------------------------------------------------

  def list_runs(conn, params) do
    with {:ok, limit, offset} <- fetch_pagination(params) do
      runs =
        from(r in "runs",
          # GF-855: expose inserted_at so the Trail "Filed" field reflects when the run was
          # actually recorded (monotonic), not the nullable/derived started_at.
          select: %{
            run_id: r.run_id,
            status: r.status,
            started_at: r.started_at,
            inserted_at: r.inserted_at
          },
          # GF-855: order by inserted_at (row-creation time — monotonic, always set), NOT
          # started_at (nullable + derived from span data → a null/stale value would sink a
          # freshly-filed run to the bottom or float a null-date run to the top). Closes the
          # "run is in the DB but looks missing in Trail" class of bug.
          order_by: [desc: r.inserted_at],
          limit: ^limit,
          offset: ^offset
        )
        |> Repo.all()

      run_ids = Enum.map(runs, & &1.run_id)
      span_counts = count_by_run(run_ids, false)
      error_counts = count_by_run(run_ids, true)

      runs =
        Enum.map(runs, fn run ->
          Map.merge(run, %{
            span_count: Map.get(span_counts, run.run_id, 0),
            error_count: Map.get(error_counts, run.run_id, 0)
          })
        end)

      total = Repo.aggregate(from(r in "runs"), :count)
      json(conn, %{runs: runs, total: total, limit: limit, offset: offset})
    else
      :error -> bad_request(conn)
    end
  end

  def get_run(conn, %{"run_id" => run_id}) do
    run =
      from(r in "runs",
        where: r.run_id == ^run_id,
        select: %{
          run_id: r.run_id,
          status: r.status,
          started_at: r.started_at,
          ended_at: r.ended_at
        }
      )
      |> Repo.one()

    case run do
      nil ->
        send_resp(conn, 404, "not found")

      meta ->
        # Skeleton — payload deliberately omitted (the waterfall UI fetches the payload on-demand).
        spans =
          from(l in "ledger_entries",
            where: l.run_id == ^run_id,
            select: %{
              id: l.id,
              seq: l.seq,
              epoch_id: l.epoch_id,
              event_type: l.event_type,
              hash: l.hash,
              # GF-793: expose the span_id projection — React builds the tree from parent_span_id → span_id.
              span_id: l.span_id,
              parent_span_id: l.parent_span_id,
              started_at: l.started_at,
              ended_at: l.ended_at,
              status: l.status
            },
            order_by: [asc: l.epoch_id, asc: l.seq]
          )
          |> Repo.all()

        # GF-828: flag runs produced by a cancelled replay (orphan spans look normal
        # otherwise). %{status: "cancelled"} | nil — the FE banner decides what to show.
        replay_job = Cassettes.get_replay_job_for_run(run_id)
        json(conn, %{run: meta, spans: spans, replay_job: replay_job})
    end
  end

  def get_span(conn, %{"run_id" => run_id, "id" => id}) do
    case Integer.parse(id) do
      {span_pk, ""} ->
        # The only endpoint where the payload (JSONB) goes out — single row, on-demand.
        span =
          from(l in "ledger_entries",
            where: l.id == ^span_pk and l.run_id == ^run_id,
            select: %{
              id: l.id,
              seq: l.seq,
              epoch_id: l.epoch_id,
              event_type: l.event_type,
              hash: l.hash,
              started_at: l.started_at,
              ended_at: l.ended_at,
              status: l.status,
              payload: l.payload
            }
          )
          |> Repo.one()

        case span do
          nil -> send_resp(conn, 404, "not found")
          row -> json(conn, row)
        end

      _ ->
        send_resp(conn, 400, "invalid span id")
    end
  end

  def verify_run(conn, %{"run_id" => run_id}) do
    # verify_ledger/1 returns {:ok, count} | {:error, :chain_broken}. A nonexistent
    # run → {:ok, 0} (an empty chain is valid), i.e. no :not_found branch.
    case Ledger.verify_ledger(run_id) do
      {:ok, count} ->
        json(conn, %{run_id: run_id, verified: true, span_count: count, error: nil})

      {:error, :chain_broken} ->
        json(conn, %{run_id: run_id, verified: false, span_count: nil, error: "chain_broken"})
    end
  end

  # --------------------------------------------------------------------------
  # Evals (metadata only — Comparator.compare/2 is NOT called, it is O(n) memory)
  # --------------------------------------------------------------------------

  def list_evals(conn, params) do
    with {:ok, limit, offset} <- fetch_pagination(params) do
      evals =
        from(e in "evals",
          select: %{id: e.eval_id, name: e.name, status: e.status, created_at: e.inserted_at},
          order_by: [desc: e.inserted_at],
          limit: ^limit,
          offset: ^offset
        )
        |> Repo.all()

      total = Repo.aggregate(from(e in "evals"), :count)
      json(conn, %{evals: evals, total: total, limit: limit, offset: offset})
    else
      :error -> bad_request(conn)
    end
  end

  def get_eval(conn, %{"id" => eval_id}) do
    case Evals.get_eval(eval_id) do
      nil ->
        send_resp(conn, 404, "not found")

      eval ->
        run_ids = Enum.map(eval.runs, & &1.run_id)
        span_counts = count_by_run(run_ids, false)

        runs =
          Enum.map(run_ids, fn run_id ->
            %{run_id: run_id, span_count: Map.get(span_counts, run_id, 0)}
          end)

        json(conn, %{
          eval: %{
            id: eval.eval_id,
            name: eval.name,
            status: eval.status,
            created_at: eval.inserted_at
          },
          runs: runs
        })
    end
  end

  @doc """
  GF-793: compares two runs within an eval via `Evals.Comparator` (O(n),
  works only with span metadata — no payload in the response). The response maps
  EXACTLY the actual return type of `compare/2`: `summary` + `differences` (NOT verdict/diffs).
  """
  def compare_eval(conn, %{"id" => eval_id} = params) do
    run_a_id = params["run_a"]
    run_b_id = params["run_b"]

    cond do
      is_nil(run_a_id) or is_nil(run_b_id) ->
        conn |> put_status(400) |> json(%{error: "run_a and run_b params required"})

      is_nil(Evals.get_eval(eval_id)) ->
        send_resp(conn, 404, "not found")

      true ->
        case Evals.compare(run_a_id, run_b_id) do
          {:ok, result} ->
            json(conn, %{
              eval_id: eval_id,
              run_a: run_a_id,
              run_b: run_b_id,
              summary: result["summary"],
              differences: result["differences"]
            })

          {:error, :run_not_found} ->
            send_resp(conn, 404, "not found")

          {:error, :different_eval} ->
            conn |> put_status(422) |> json(%{error: "runs belong to different evals"})
        end
    end
  end

  # --------------------------------------------------------------------------
  # Cassettes
  # --------------------------------------------------------------------------

  def list_cassettes(conn, params) do
    with {:ok, limit, offset} <- fetch_pagination(params) do
      # A direct metadata query (NOT Cassettes.list/0 — that loads the whole `snapshot` array → OOM).
      cassettes =
        from(c in "cassettes",
          select: %{
            id: c.cassette_id,
            run_id: c.run_id,
            name: c.name,
            recorded_at: c.recorded_at,
            inserted_at: c.inserted_at
          },
          order_by: [desc: c.recorded_at],
          limit: ^limit,
          offset: ^offset
        )
        |> Repo.all()

      total = Repo.aggregate(from(c in "cassettes"), :count)
      json(conn, %{cassettes: cassettes, total: total, limit: limit, offset: offset})
    else
      :error -> bad_request(conn)
    end
  end

  @doc """
  GF-798: async replay. Enqueues a job and returns `202 Accepted` with `job_id`
  immediately (was synchronous 200 with the full result). The replay runs on a
  Task.Supervisor task; poll `GET /api/cassettes/replay_jobs/:id` for the outcome.
  Optional `new_run_id` param; otherwise a UUID-based replay run id is generated.
  """
  def replay_cassette(conn, %{"id" => cassette_id}) do
    # GF-850: validate only a user-supplied new_run_id (the generated fallback is trusted →
    # no regression on no-param replay). Malformed/oversized → 400 before enqueue.
    supplied = Map.get(conn.params, "new_run_id")

    if is_binary(supplied) and not ValidationPlug.valid_run_id?(supplied) do
      conn |> put_status(400) |> json(%{error: "invalid_run_id"})
    else
      replay_validated(conn, cassette_id, supplied || generate_replay_run_id(cassette_id))
    end
  end

  defp replay_validated(conn, cassette_id, new_run_id) do
    case Cassettes.enqueue_replay(cassette_id, new_run_id) do
      {:ok, job} ->
        conn |> put_status(202) |> json(%{job_id: job.id, status: job.status})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "cassette_not_found"})

      # GF-832: unique_constraint on new_run_id → clean 409 instead of CaseClauseError → 500.
      {:error, %Ecto.Changeset{}} ->
        conn |> put_status(409) |> json(%{error: "new_run_id_already_exists"})
    end
  end

  @doc "GF-798: poll an async replay job's status + result."
  def get_replay_job(conn, %{"id" => id}) do
    case Cassettes.get_replay_job(id) do
      {:ok, job} -> json(conn, %{id: job.id, status: job.status, result: job.result})
      {:error, :not_found} -> send_resp(conn, 404, "not found")
    end
  end

  @doc "GF-823: cancel an async replay job (pending/running → cancelled)."
  def cancel_replay_job(conn, %{"id" => id}) do
    case Cassettes.cancel_replay_job(id) do
      {:ok, _job} -> json(conn, %{status: "cancelled"})
      {:error, :not_found} -> send_resp(conn, 404, "not found")
      {:error, :already_terminal} -> conn |> put_status(409) |> json(%{error: "already_terminal"})
    end
  end

  defp generate_replay_run_id(cassette_id), do: "replay-#{cassette_id}-#{Ecto.UUID.generate()}"

  @doc "GF-945: record a cassette snapshot for a given run via the Caddy-proxied port 4001 API."
  def record_cassette(conn, %{"run_id" => run_id, "cassette_id" => cassette_id} = params) do
    name = Map.get(params, "name", run_id)

    case Cassettes.record(run_id, cassette_id: cassette_id, name: name) do
      {:ok, cassette} ->
        conn
        |> put_status(201)
        |> json(%{
          cassette: %{
            "id" => cassette.cassette_id,
            "run_id" => cassette.run_id,
            "name" => cassette.name,
            "recorded_at" => cassette.recorded_at,
            "inserted_at" => cassette.inserted_at
          }
        })

      {:error, :run_not_found} ->
        conn |> put_status(404) |> json(%{error: "run_not_found"})

      {:error, :missing_cassette_id} ->
        # Defensive: empty string "" passes pattern match but fails domain guard
        conn |> put_status(400) |> json(%{error: "missing_cassette_id"})

      {:error, %Ecto.Changeset{}} ->
        conn |> put_status(422) |> json(%{error: "validation_failed"})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  def record_cassette(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: "missing_required_params", message: "run_id and cassette_id are required"})
  end

  # --------------------------------------------------------------------------
  # CORS preflight — dead target. Corsica (the first plug in :api) halts an allowed-origin
  # preflight first; a disallowed origin is halted by AuthPlug (401). The route must exist
  # so the OPTIONS request passes through the `:api` pipeline (otherwise Phoenix 404 → Corsica won't run).
  # --------------------------------------------------------------------------

  def preflight(conn, _params), do: send_resp(conn, 204, "")

  # --------------------------------------------------------------------------
  # Private
  # --------------------------------------------------------------------------

  # GF-850: controller plug — rejects a malformed/oversized :run_id (399+ chars, slash,
  # disallowed characters) with 400 before the action touches the DB. halt() stops dispatch.
  defp validate_run_id(conn, _opts) do
    if ValidationPlug.valid_run_id?(conn.params["run_id"]) do
      conn
    else
      conn |> put_status(400) |> json(%{error: "invalid_run_id"}) |> halt()
    end
  end

  defp count_by_run([], _errors_only), do: %{}

  defp count_by_run(run_ids, false) do
    from(l in "ledger_entries",
      where: l.run_id in ^run_ids,
      group_by: l.run_id,
      select: {l.run_id, count(l.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp count_by_run(run_ids, true) do
    from(l in "ledger_entries",
      where: l.run_id in ^run_ids and l.status == "error",
      group_by: l.run_id,
      select: {l.run_id, count(l.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp fetch_pagination(params) do
    with {:ok, limit} <- parse_int(Map.get(params, "limit"), 50),
         {:ok, offset} <- parse_int(Map.get(params, "offset"), 0) do
      {:ok, limit |> max(0) |> min(200), max(offset, 0)}
    end
  end

  defp parse_int(nil, default), do: {:ok, default}

  defp parse_int(value, _default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_int(_, _), do: :error

  defp bad_request(conn), do: send_resp(conn, 400, "invalid pagination params")
end
