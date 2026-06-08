defmodule SpanChain.Ledger do
  @moduledoc "Append-only hash-chain Ledger — a persisted OTLP span audit trail."

  @behaviour SpanChain.Ledger.Behaviour

  use Ecto.Schema

  import Ecto.Query

  alias SpanChain.{PayloadSerializer, Repo}

  @type t :: %__MODULE__{
          run_id: String.t(),
          epoch_id: non_neg_integer(),
          seq: non_neg_integer(),
          hash: String.t(),
          prev_hash: String.t() | nil,
          parent_span_id: String.t() | nil,
          span_id: String.t() | nil,
          trace_id: String.t() | nil,
          started_at: DateTime.t() | nil,
          ended_at: DateTime.t() | nil,
          status: String.t() | nil,
          event_type: String.t(),
          payload: map(),
          inserted_at: DateTime.t() | nil
        }

  @type entry :: %{
          run_id: String.t(),
          epoch_id: non_neg_integer(),
          seq: non_neg_integer(),
          hash: String.t(),
          prev_hash: String.t() | nil,
          parent_span_id: String.t() | nil,
          span_id: String.t() | nil,
          trace_id: String.t() | nil,
          started_at: DateTime.t() | nil,
          ended_at: DateTime.t() | nil,
          status: String.t() | nil,
          event_type: String.t(),
          payload: map(),
          inserted_at: DateTime.t()
        }

  schema "ledger_entries" do
    field(:run_id, :string)
    field(:epoch_id, :integer)
    field(:seq, :integer)
    field(:hash, :string)
    field(:prev_hash, :string)
    field(:parent_span_id, :string)
    # GF-669: projections from the payload for fast reads. Not in compute_hash —
    # the payload is still the authoritative source for chain integrity.
    field(:span_id, :string)
    # GF-653: trace_id projection for W3C OTel correlation (GF-735 future). Not in the hash.
    field(:trace_id, :string)
    field(:started_at, :utc_datetime)
    field(:ended_at, :utc_datetime)
    # GF-790: status projection from the payload (per-span status for waterfall error highlight).
    # Not in compute_hash — a projection, not content (like span_id/trace_id). Nullable.
    field(:status, :string)
    field(:event_type, :string)
    field(:payload, :map, default: %{})

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  # --------------------------------------------------------------------------
  # Hash chain primitives
  # --------------------------------------------------------------------------

  @doc """
  SHA256 hash for a single ledger entry. The input includes `run_id` and `epoch_id`
  (GF-787) — so the entry is cryptographically bound to its run and epoch, not just
  by the SQL filter in `verify_ledger/1`. Without them an entry could be silently moved
  under a different `run_id`/`epoch_id` in the DB without detection.

  `run_id`/`epoch_id` are NOT NULL — no `|| "nil"` fallback. `parent_span_id`
  belongs in the hash (hierarchy), otherwise it could be silently overwritten; `nil` is hashed
  as the literal `"nil"` (like `prev_hash`).
  """
  @spec compute_hash(
          non_neg_integer(),
          String.t() | nil,
          String.t(),
          map(),
          String.t() | nil,
          String.t(),
          non_neg_integer()
        ) :: String.t()
  def compute_hash(seq, prev_hash, event_type, payload, parent_span_id, run_id, epoch_id) do
    data =
      "#{Integer.to_string(seq)}:#{prev_hash || "nil"}:#{event_type}:#{PayloadSerializer.canonical_encode(payload)}:#{parent_span_id || "nil"}:#{run_id}:#{Integer.to_string(epoch_id)}"

    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  @doc """
  Builds a ledger entry with the computed hash. Called by the SessionGenServer on
  every incoming span.
  """
  @spec build_entry(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          String.t() | nil,
          String.t(),
          map(),
          String.t() | nil
        ) :: entry()
  def build_entry(run_id, epoch_id, seq, prev_hash, event_type, payload, parent_span_id \\ nil) do
    # GF-653 audit (Scenario A): OtlpTranslator emits snake_case
    # (`"span_id"`, `"trace_id"`) — so the span_id projection is correctly
    # populated for the OTLP path too, no fix needed. The `|| "traceId"` fallback
    # is defensive for unidentified payload sources.
    %{
      run_id: run_id,
      epoch_id: epoch_id,
      seq: seq,
      hash: compute_hash(seq, prev_hash, event_type, payload, parent_span_id, run_id, epoch_id),
      prev_hash: prev_hash,
      parent_span_id: parent_span_id,
      span_id: Map.get(payload, "span_id"),
      trace_id: Map.get(payload, "trace_id") || Map.get(payload, "traceId"),
      started_at: parse_datetime(Map.get(payload, "started_at")),
      ended_at: parse_datetime(Map.get(payload, "ended_at")),
      # GF-790: status projection — after compute_hash, hash input unchanged.
      status: Map.get(payload, "status"),
      event_type: event_type,
      payload: payload,
      inserted_at: DateTime.utc_now()
    }
  end

  # GF-669: defensive ISO8601 parser. Never crashes — non-binary / non-parseable
  # input returns nil. The projection columns are nullable; a parse error must not block ingestion.
  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  # --------------------------------------------------------------------------
  # Persistence
  # --------------------------------------------------------------------------

  @doc """
  Batch insert of ledger records. Idempotent thanks to on_conflict: :nothing
  on the unique index (run_id, epoch_id, seq). Emits the :telemetry event
  `[:gf, :ledger, :batch_insert, :start | :stop]` with `count` in measurements.
  """
  @spec insert_batch([entry()]) :: {non_neg_integer(), nil | [term()]}
  def insert_batch([]), do: {0, nil}

  def insert_batch(entries) when is_list(entries) do
    count = length(entries)
    start_mono = System.monotonic_time()
    run_ids = entries |> Enum.map(& &1.run_id) |> Enum.uniq()

    :telemetry.execute(
      [:gf, :ledger, :batch_insert, :start],
      %{count: count, monotonic_time: start_mono},
      %{run_ids: run_ids}
    )

    {inserted, _} =
      result =
      Repo.insert_all(__MODULE__, entries,
        on_conflict: :nothing,
        conflict_target: [:run_id, :epoch_id, :seq]
      )

    :telemetry.execute(
      [:gf, :ledger, :batch_insert, :stop],
      %{count: count, inserted: inserted, duration: System.monotonic_time() - start_mono},
      %{run_ids: run_ids}
    )

    result
  end

  # --------------------------------------------------------------------------
  # Integrity verification
  # --------------------------------------------------------------------------

  @doc """
  Re-hashes the chain from DB end-to-end. Returns `{:ok, count}` if
  every record (a) has a `hash` matching the recomputed value and (b) a `prev_hash`
  matching the hash of the immediately preceding record — seamlessly across
  all epochs. Returns `{:error, :chain_broken}` otherwise.

  GF-666: the epoch boundary is NOT a special case. `last_hash` carries
  across epochs; deleting a whole epoch in the middle of the chain shows up as
  the discrepancy `entry.prev_hash != last_hash` at the first record of the following
  epoch and returns `{:error, :chain_broken}` (Island Attack detection).

  `prev_hash: nil` is allowed only for the very first record within a
  `run_id` (`epoch_id: 0, seq: 0`).
  """
  @spec verify_ledger(String.t()) :: {:ok, non_neg_integer()} | {:error, :chain_broken}
  def verify_ledger(run_id) when is_binary(run_id) do
    entries =
      from(l in __MODULE__,
        where: l.run_id == ^run_id,
        order_by: [asc: l.epoch_id, asc: l.seq]
      )
      |> Repo.all()

    result =
      Enum.reduce_while(entries, {:ok, 0, nil}, fn e, {:ok, count, last_hash} ->
        expected_hash =
          compute_hash(
            e.seq,
            e.prev_hash,
            e.event_type,
            e.payload,
            e.parent_span_id,
            e.run_id,
            e.epoch_id
          )

        cond do
          e.prev_hash != last_hash -> {:halt, {:error, :chain_broken}}
          expected_hash != e.hash -> {:halt, {:error, :chain_broken}}
          true -> {:cont, {:ok, count + 1, e.hash}}
        end
      end)

    case result do
      {:ok, count, _last_hash} -> {:ok, count}
      {:error, _} = err -> err
    end
  end
end
