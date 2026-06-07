defmodule SpanChain.DeadLetter do
  @moduledoc """
  Záchranná síť pro batche, které selhaly při zápisu do Ledgeru po vyčerpání retry.

  Záznamy v `dead_letter_entries` **nejsou součástí hash-chainu** — jsou to
  orphaned spans pro ruční inspekci nebo offline reprocessing. Hash-chain
  v Ledgeru pokračuje bez nich (`seq` / `prev_hash` se počítá jakoby insert
  proběhl), takže `verify_ledger/1` na chybějících řádcích selže — to je
  záměrné, dead-letter explicitně signalizuje "tady jsou data, ale chybí
  v autoritativním zdroji".

  `store/3` je defenzivní — pokud i ten zápis selže (DB úplně down), jen
  zaloguje a vrátí `{:error, reason}`. GenServer volajícího se nesmí crashnout
  jen proto, že záchranná síť nefunguje.
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
  Uloží neúspěšný batch jako dead-letter záznam. Vrací `{:ok, %DeadLetter{}}`
  nebo `{:error, reason}` — nikdy nevyhazuje výjimku ven (try/rescue + log).
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

  @doc "Vrátí všechny nevyřešené dead-letter záznamy (chronologicky)."
  @spec list_unresolved() :: [t()]
  def list_unresolved do
    from(d in __MODULE__, where: d.resolved == false, order_by: [asc: d.inserted_at])
    |> Repo.all()
  end

  @doc """
  Označí dead-letter záznam jako vyřešený. `resolved_at` se nastaví automaticky
  přes `timestamps(updated_at: :resolved_at)`.
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
