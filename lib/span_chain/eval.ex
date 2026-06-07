defmodule SpanChain.Eval do
  @moduledoc """
  Eval-level metadata agregátor (GF-706). Zastřešující doména pro porovnávání
  více `runs` se stejným záměrem (např. "stejná otázka, 3 různé modely").

  Klient generuje `eval_id` a posílá ho jako OTLP
  `resource.attributes["gf.eval_id"]`. Backend pasivně upsertuje associaci
  v `SessionGenServer.init/1` (best-effort, nesmí crashnout SGS).
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

  @doc "Changeset pro create/update — `eval_id` je required."
  @spec changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(eval, attrs) do
    eval
    |> cast(attrs, [:eval_id, :name, :description, :status])
    |> validate_required([:eval_id])
  end
end
