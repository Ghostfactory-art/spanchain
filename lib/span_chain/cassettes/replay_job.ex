defmodule SpanChain.Cassettes.ReplayJob do
  @moduledoc """
  Async replay job state (GF-798). One row per `POST /api/cassettes/:id/replay`:
  enqueued as `"running"`, flipped to `"completed"` (with the `Replayer` result map)
  or `"failed"` (with an `%{"error" => ...}` map) by the Task.Supervisor worker.
  Read via the polling endpoint. UUID primary key (globally unique, VM-lifecycle
  independent — same rationale as GF-726 replay run ids).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          cassette_id: String.t(),
          new_run_id: String.t(),
          status: String.t(),
          result: map() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "replay_jobs" do
    field(:cassette_id, :string)
    field(:new_run_id, :string)
    field(:status, :string, default: "running")
    field(:result, :map)
    timestamps()
  end

  @doc "Required: cassette_id, new_run_id, status."
  @spec changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(job, attrs) do
    job
    |> cast(attrs, [:cassette_id, :new_run_id, :status, :result])
    |> validate_required([:cassette_id, :new_run_id, :status])
    |> validate_inclusion(:status, ["pending", "running", "completed", "failed", "cancelled"])
    # GF-832: DB unique violation → readable {:error, changeset}, not Ecto.ConstraintError.
    |> unique_constraint(:new_run_id)
  end
end
