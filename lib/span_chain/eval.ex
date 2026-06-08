defmodule SpanChain.Eval do
  @moduledoc """
  Eval-level metadata aggregator (GF-706). An umbrella domain for comparing
  multiple `runs` with the same intent (e.g. "same question, 3 different models").

  The client generates the `eval_id` and sends it as the OTLP
  `resource.attributes["gf.eval_id"]`. The backend passively upserts the association
  in `SessionGenServer.init/1` (best-effort, must not crash the SGS).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          eval_id: String.t(),
          name: String.t() | nil,
          description: String.t() | nil,
          status: String.t(),
          runs: [SpanChain.Run.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  @primary_key {:eval_id, :string, autogenerate: false}
  schema "evals" do
    field(:name, :string)
    field(:description, :string)
    field(:status, :string, default: "running")

    has_many(:runs, SpanChain.Run,
      foreign_key: :eval_id,
      references: :eval_id
    )

    timestamps()
  end

  @doc "Changeset for create/update — `eval_id` is required."
  @spec changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(eval, attrs) do
    eval
    |> cast(attrs, [:eval_id, :name, :description, :status])
    |> validate_required([:eval_id])
  end
end
