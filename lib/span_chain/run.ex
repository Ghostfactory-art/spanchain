defmodule SpanChain.Run do
  @moduledoc "Run-level metadata agregátor. Jeden řádek per run_id."

  use Ecto.Schema

  @type t :: %__MODULE__{
          run_id: String.t(),
          status: String.t(),
          agent_name: String.t() | nil,
          model: String.t() | nil,
          env: String.t() | nil,
          eval_id: String.t() | nil,
          system_prompt_hash: String.t() | nil,
          temperature: float() | nil,
          version: String.t() | nil,
          started_at: DateTime.t() | nil,
          ended_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @primary_key {:run_id, :string, autogenerate: false}
  schema "runs" do
    field(:status, :string, default: "running")
    field(:agent_name, :string)
    field(:model, :string)
    field(:env, :string)
    # GF-706: eval_id field MUSÍ být explicitně před belongs_to s define_field: false,
    # jinak by Ecto nevytvořil sloupec ve schemata projection.
    field(:eval_id, :string)
    # GF-748: gf.agent.* projection — first-wins via Pipeline upsert (COALESCE)
    field(:system_prompt_hash, :string)
    field(:temperature, :float)
    field(:version, :string)
    field(:started_at, :utc_datetime)
    field(:ended_at, :utc_datetime)

    belongs_to(:eval, SpanChain.Eval,
      foreign_key: :eval_id,
      references: :eval_id,
      type: :string,
      define_field: false
    )

    timestamps(inserted_at: :inserted_at, updated_at: false)
  end
end
