defmodule SpanChain.DeadLetter do
  @moduledoc """
  A safety net for batches that failed to write to the Ledger after retries were exhausted.

  Records in `dead_letter_entries` are **not part of the hash chain** — they are
  orphaned spans for manual inspection or offline reprocessing. The hash chain
  in the Ledger continues without them (`seq` / `prev_hash` is computed as if the insert
  had happened), so `verify_ledger/1` fails on the missing rows — that is
  intentional; the dead-letter explicitly signals "here is the data, but it is missing
  from the authoritative source".

  `store/3` is defensive — if even that write fails (DB completely down), it just
  logs and returns `{:error, reason}`. The caller's GenServer must not crash
  just because the safety net is down.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  require Logger

  alias SpanChain.Repo

  @type t :: %__MODULE__{
          id: integer() | nil,
          run_id: String.t(),
          batch: map(),
          error_reason: String.t(),
          resolved: boolean(),
          inserted_at: DateTime.t() | nil,
          resolved_at: DateTime.t() | nil
        }

  schema "dead_letter_entries" do
    field(:run_id, :string)
    field(:batch, :map)
    field(:error_reason, :string)
    field(:resolved, :boolean, default: false)

    timestamps(type: :utc_datetime_usec, updated_at: :resolved_at)
  end

  # --------------------------------------------------------------------------
  # Public API
  # --------------------------------------------------------------------------

  @doc """
  Stores a failed batch as a dead-letter record. Returns `{:ok, %DeadLetter{}}`
  or `{:error, reason}` — never raises an exception outward (try/rescue + log).
  """
  @spec store(String.t(), [map()], term()) :: {:ok, t()} | {:error, term()}
  def store(run_id, batch, reason) when is_binary(run_id) and is_list(batch) do
    attrs = %{
      run_id: run_id,
      batch: %{"spans" => Enum.map(batch, &serialize_entry/1)},
      error_reason: format_reason(reason)
    }

    try do
      %__MODULE__{}
      |> cast(attrs, [:run_id, :batch, :error_reason])
      |> validate_required([:run_id, :batch, :error_reason])
      |> Repo.insert()
    rescue
      e ->
        Logger.error(
          "[DeadLetter] store failed run_id=#{run_id} batch_size=#{length(batch)} " <>
            "store_error=#{inspect(e)} original_reason=#{inspect(reason)}"
        )

        {:error, e}
    catch
      kind, value ->
        Logger.error(
          "[DeadLetter] store caught #{kind} run_id=#{run_id} value=#{inspect(value)} " <>
            "original_reason=#{inspect(reason)}"
        )

        {:error, {kind, value}}
    end
  end

  @doc "Returns all unresolved dead-letter records (chronologically)."
  @spec list_unresolved() :: [t()]
  def list_unresolved do
    from(d in __MODULE__, where: d.resolved == false, order_by: [asc: d.inserted_at])
    |> Repo.all()
  end

  @doc """
  Marks a dead-letter record as resolved. `resolved_at` is set automatically
  via `timestamps(updated_at: :resolved_at)`.
  """
  @spec resolve(integer()) :: {:ok, t()} | {:error, :not_found | Ecto.Changeset.t()}
  def resolve(id) when is_integer(id) do
    case Repo.get(__MODULE__, id) do
      nil ->
        {:error, :not_found}

      entry ->
        entry
        |> change(resolved: true)
        |> Repo.update()
    end
  end

  # --------------------------------------------------------------------------
  # Private — serialization
  # --------------------------------------------------------------------------

  defp serialize_entry(entry) when is_map(entry) do
    Map.new(entry, fn
      {k, %DateTime{} = dt} -> {to_string(k), DateTime.to_iso8601(dt)}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
