defmodule GfExperiment.Repo.Migrations.CreateSchemaPostgres do
  @moduledoc """
  GF-704: čistá Postgres schema migrace. Konsoliduje finální stav z 10 SQLite
  migrací (archivované v `priv/repo/migrations_sqlite/`, git history) do jediné
  Postgres migrace.

  Klíčové adapter-specifické rozdíly oproti SQLite:
  - `ledger_entries.id` je `:bigserial` (Postgres auto-increment sequence) — SQLite
    aliasovalo `:integer primary_key` na rowid, Postgres `:integer` by sequence neměl
    a `Repo.insert_all` by selhal na NOT NULL.
  - `:map` sloupce (`payload`, `batch`, `snapshot`) Postgres uloží jako `jsonb`.
  - FK `runs.eval_id → evals.eval_id` je nyní reálně vynucený (SQLite ho bez
    `PRAGMA foreign_keys` ignoroval) → `evals` se vytváří PŘED `runs`.
  """
  use Ecto.Migration

  def change do
    # evals — FK target pro runs.eval_id, vytvořit jako první.
    create table(:evals, primary_key: false) do
      add :eval_id, :string, primary_key: true, null: false
      add :name, :string
      add :description, :text
      add :status, :string, null: false, default: "running"
      timestamps()
    end

    # runs — eval_id FK references evals (musí existovat dřív).
    create table(:runs, primary_key: false) do
      add :run_id, :string, primary_key: true, null: false
      add :status, :string, null: false, default: "running"
      add :agent_name, :string
      add :model, :string
      add :env, :string
      add :started_at, :utc_datetime
      add :ended_at, :utc_datetime
      add :eval_id, references(:evals, column: :eval_id, type: :string, on_delete: :nothing)
      add :system_prompt_hash, :string
      add :temperature, :float
      add :version, :string
      timestamps(inserted_at: :inserted_at, updated_at: false)
    end

    create index(:runs, [:eval_id])

    # ledger_entries — hash-chain source of truth. id musí být bigserial na Postgres.
    create table(:ledger_entries, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :run_id, :string, null: false
      add :epoch_id, :integer, null: false
      add :seq, :integer, null: false
      add :hash, :string, null: false
      add :prev_hash, :string
      add :parent_span_id, :string
      add :span_id, :string
      add :trace_id, :string
      add :started_at, :utc_datetime
      add :ended_at, :utc_datetime
      add :event_type, :string, null: false
      add :payload, :map, null: false, default: %{}

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    # ADR-003 conflict_target — musí odpovídat Ledger.insert_batch on_conflict.
    create unique_index(:ledger_entries, [:run_id, :epoch_id, :seq])
    create index(:ledger_entries, [:run_id, :inserted_at])
    create index(:ledger_entries, [:span_id])
    create index(:ledger_entries, [:run_id, :started_at])
    create index(:ledger_entries, [:trace_id])

    # dead_letter_entries — záchranná síť mimo hash-chain (default bigserial id).
    create table(:dead_letter_entries) do
      add :run_id, :string, null: false
      add :batch, :map, null: false
      add :error_reason, :string, null: false
      add :resolved, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec, updated_at: :resolved_at)
    end

    create index(:dead_letter_entries, [:run_id])
    create index(:dead_letter_entries, [:resolved])

    # cassettes — replay snapshoty (GF-712).
    create table(:cassettes, primary_key: false) do
      add :cassette_id, :string, primary_key: true, null: false
      add :run_id, :string, null: false
      add :name, :string
      add :snapshot, :map, null: false
      add :recorded_at, :utc_datetime_usec, null: false
      timestamps()
    end

    create index(:cassettes, [:run_id])
  end
end
