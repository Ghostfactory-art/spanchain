defmodule GfExperiment.Repo.Migrations.AddStatusToLedgerEntries do
  use Ecto.Migration

  # GF-790 — stav před implementací (Krok 0, ověřeno proti konsolidované PG migraci
  # 20260527120000_create_schema_postgres.exs):
  #   ledger_entries.started_at: EXISTS (GF-669, přežil GF-704 konsolidaci)
  #   ledger_entries.ended_at:   EXISTS
  #   ledger_entries.status:     MISSING ← přidáno zde
  #   runs.started_at:           EXISTS
  #   ensure_run_records LEAST:  MISSING ← doplněno v pipeline.ex
  #
  # Čistě aditivní: status není v compute_hash (projekce, ne content), nullable →
  # existující řádky NULL, zpětná kompatibilita. `change`/`add` je auto-reverzibilní.
  def change do
    alter table(:ledger_entries) do
      add :status, :string
    end
  end
end
