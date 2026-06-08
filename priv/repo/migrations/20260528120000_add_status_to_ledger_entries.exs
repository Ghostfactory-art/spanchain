defmodule GfExperiment.Repo.Migrations.AddStatusToLedgerEntries do
  use Ecto.Migration

  # GF-790 — state before implementation (Step 0, verified against the consolidated PG migration
  # 20260527120000_create_schema_postgres.exs):
  #   ledger_entries.started_at: EXISTS (GF-669, survived the GF-704 consolidation)
  #   ledger_entries.ended_at:   EXISTS
  #   ledger_entries.status:     MISSING ← added here
  #   runs.started_at:           EXISTS
  #   ensure_run_records LEAST:  MISSING ← added in pipeline.ex
  #
  # Purely additive: status is not in compute_hash (a projection, not content), nullable →
  # existing rows are NULL, backward compatible. `change`/`add` is auto-reversible.
  def change do
    alter table(:ledger_entries) do
      add :status, :string
    end
  end
end
