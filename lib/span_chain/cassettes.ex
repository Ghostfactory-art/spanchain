defmodule SpanChain.Cassettes do
  @moduledoc """
  Public API pro Cassettes doménu (GF-712). Cassette = DB-backed snapshot
  payload streamu pro daný `run_id`, replayovatelný přes
  `SessionGenServer → Pipeline → Ledger` cestu (hash-chain invariant
  zachován — žádný bypass).
  """

  import Ecto.Query, only: [from: 2]

  alias SpanChain.{Cassette, Ledger, Repo}
  alias SpanChain.Cassettes.{Replayer, ReplayJob}

  @spec record(String.t(), keyword()) ::
          {:ok, Cassette.t()}
          | {:error, :run_not_found | :missing_cassette_id | Ecto.Changeset.t()}
  def record(run_id, opts \\ []) when is_binary(run_id) do
    cassette_id = opts[:cassette_id]
    name = opts[:name]

    cond do
      is_nil(cassette_id) or cassette_id == "" ->
        {:error, :missing_cassette_id}

      true ->
        case load_payloads(run_id) do
          [] ->
            {:error, :run_not_found}

          payloads ->
            attrs = %{
              cassette_id: cassette_id,
              run_id: run_id,
              name: name,
              snapshot: payloads,
              recorded_at: DateTime.utc_now()
            }

            %Cassette{}
            |> Cassette.changeset(attrs)
            |> Repo.insert()
        end
    end
  end

  @spec get(String.t()) :: {:ok, Cassette.t()} | {:error, :not_found}
  def get(cassette_id) when is_binary(cassette_id) do
    case Repo.get(Cassette, cassette_id) do
      nil -> {:error, :not_found}
      cassette -> {:ok, cassette}
    end
  end

  @spec list() :: [Cassette.t()]
  def list do
    from(c in Cassette, order_by: [desc: c.recorded_at])
    |> Repo.all()
  end

  @spec replay(String.t(), keyword()) ::
          {:ok, Replayer.result()} | {:error, :not_found | :timeout | term()}
  def replay(cassette_id, opts \\ []) when is_binary(cassette_id) do
    with {:ok, cassette} <- get(cassette_id) do
      Replayer.replay(cassette, opts)
    end
  end

  # --------------------------------------------------------------------------
  # Async replay jobs (GF-798)
  # --------------------------------------------------------------------------

  @doc """
  Enqueue an async replay. Inserts a `ReplayJob` (`status: "running"`) and spawns a
  fire-and-forget `Task.Supervisor` task that runs the replay and updates the row to
  `"completed"`/`"failed"`. Returns `{:ok, job}` immediately, or `{:error, :not_found}`
  if the cassette does not exist. State is read back via `get_replay_job/1` (polling).
  """
  @spec enqueue_replay(String.t(), String.t()) ::
          {:ok, ReplayJob.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def enqueue_replay(cassette_id, new_run_id)
      when is_binary(cassette_id) and is_binary(new_run_id) do
    with {:ok, _cassette} <- get(cassette_id),
         {:ok, job} <-
           %ReplayJob{}
           |> ReplayJob.changeset(%{
             cassette_id: cassette_id,
             new_run_id: new_run_id,
             status: "running"
           })
           |> Repo.insert() do
      Task.Supervisor.start_child(SpanChain.TaskSupervisor, fn -> run_replay_job(job) end)
      {:ok, job}
    end
  end

  @doc """
  Fetch a replay job by UUID. Returns `{:error, :not_found}` for an unknown id or a
  malformed (non-UUID) id — never raises (no FallbackController in the API scope).
  """
  @spec get_replay_job(String.t()) :: {:ok, ReplayJob.t()} | {:error, :not_found}
  def get_replay_job(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Repo.get(ReplayJob, uuid) do
          nil -> {:error, :not_found}
          job -> {:ok, job}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Cancel a replay job: flip a `pending`/`running` job to `"cancelled"` (GF-823). UUID-cast
  guarded (malformed/unknown id → `{:error, :not_found}`); already-terminal jobs
  (`completed`/`failed`/`cancelled`) → `{:error, :already_terminal}`. The fire-and-forget task
  may still finish, but the polling status reflects the cancellation.
  """
  @spec cancel_replay_job(String.t()) ::
          {:ok, ReplayJob.t()} | {:error, :not_found | :already_terminal | Ecto.Changeset.t()}
  def cancel_replay_job(id) when is_binary(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %ReplayJob{} = job <- Repo.get(ReplayJob, uuid) do
      case job.status do
        s when s in ["completed", "failed", "cancelled"] ->
          {:error, :already_terminal}

        _ ->
          job |> ReplayJob.changeset(%{status: "cancelled"}) |> Repo.update()
      end
    else
      :error -> {:error, :not_found}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Return `%{status: status}` if a replay job ingested into `run_id` (i.e. a job whose
  `new_run_id` equals it), else `nil`. Read-only; used by the API to flag a run produced
  by a **cancelled** replay — those orphan spans live permanently in the append-only
  ledger and `verify_ledger/1` passes them, so the run looks normal despite being
  incomplete (GF-828). `nil`/malformed `run_id` → `nil` (no crash). `new_run_id` is a
  plain string column, so a direct match — no UUID cast. `limit: 1` + newest-first keeps
  `Repo.one/1` safe even if a `new_run_id` were ever reused.
  """
  @spec get_replay_job_for_run(term()) :: %{status: String.t()} | nil
  def get_replay_job_for_run(run_id) when is_binary(run_id) do
    from(j in ReplayJob,
      where: j.new_run_id == ^run_id,
      order_by: [desc: j.inserted_at],
      limit: 1,
      select: %{status: j.status}
    )
    |> Repo.one()
  end

  def get_replay_job_for_run(_), do: nil

  @doc """
  Run a replay and write the terminal status. The Task.Supervisor task body
  (`enqueue_replay/1`); also **public so tests can drive the terminal write
  deterministically** (mirrors `ReplayJobSweeper.sweep_stuck_jobs/0`).

  `Replayer.replay/2` returns tuples (it does not raise for expected errors like
  :timeout), so branch on the tuple — only mark "completed" on {:ok, _}. try/rescue
  catches genuine exceptions; it does NOT catch :EXIT (externally killed task) —
  documented v1 limitation (job stays "running" until the sweeper reaps it).
  """
  def run_replay_job(job) do
    case replay(job.cassette_id, run_id: job.new_run_id) do
      {:ok, result} ->
        finish_replay_job(job, "completed", serialize_result(result))

      {:error, reason} ->
        finish_replay_job(job, "failed", %{"error" => inspect(reason)})
    end
  rescue
    e ->
      finish_replay_job(job, "failed", %{"error" => Exception.message(e)})
  end

  # GF-827 — atomic terminal write: only update a job that is STILL "running". Once
  # cancel_replay_job/1 has flipped it to "cancelled" (or the sweeper to "failed"), the
  # `WHERE status = 'running'` matches 0 rows and this Ghost-Task write is silently a
  # no-op — so a cancelled job can never be overwritten (no check-then-write race).
  # update_all bypasses the changeset, so updated_at is stamped here (naive_datetime,
  # matching the schema's timestamps()).
  defp finish_replay_job(%ReplayJob{} = job, status, result) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    from(j in ReplayJob, where: j.id == ^job.id and j.status == "running")
    |> Repo.update_all(set: [status: status, result: result, updated_at: now])
  end

  # Replayer.result() → jsonb-safe map with explicit string keys (matches read-back).
  defp serialize_result(%{
         run_id: run_id,
         span_count: span_count,
         hash_valid: hash_valid,
         diff: diff
       }) do
    %{
      "run_id" => run_id,
      "span_count" => span_count,
      "hash_valid" => hash_valid,
      "diff" => diff
    }
  end

  # Payload-first: ukládáme raw `payload` mapu z Ledger rows (sub-second
  # precision zachována, projekční sloupce truncated na :second by data
  # zkreslily — lesson learned z GF-706 Comparator.duration_ms bug).
  defp load_payloads(run_id) do
    from(l in Ledger,
      where: l.run_id == ^run_id,
      order_by: [asc: l.epoch_id, asc: l.seq],
      select: l.payload
    )
    |> Repo.all()
  end
end
