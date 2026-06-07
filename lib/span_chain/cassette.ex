defmodule SpanChain.Cassette do
  @moduledoc "DB-backed snapshot of a run's payload stream for deterministic replay (GF-712)."

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          cassette_id: String.t(),
          run_id: String.t(),
          name: String.t() | nil,
          snapshot: [map()],
          recorded_at: DateTime.t() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  @primary_key {:cassette_id, :string, autogenerate: false}
  schema "cassettes" do
    field(:run_id, :string)
    field(:name, :string)
    field(:snapshot, {:array, :map}, default: [])
    field(:recorded_at, :utc_datetime_usec)
    timestamps()
  end

  @doc "Required: cassette_id, run_id, snapshot, recorded_at."
  @spec changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(cassette, attrs) do
    cassette
    |> cast(attrs, [:cassette_id, :run_id, :name, :snapshot, :recorded_at])
    |> validate_required([:cassette_id, :run_id, :snapshot, :recorded_at])
  end
end
