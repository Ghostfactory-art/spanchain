defmodule SpanChain.Cassettes.Replayer do
  @moduledoc """
  Pure replay engine for Cassettes (GF-712). Pushes snapshot spans back through
  the normal `SessionGenServer → Pipeline → Ledger` path under a fresh
  `run_id`, then waits — via PubSub `{:spans_flushed, run_id}` broadcasts
  emitted by `Pipeline.handle_batch/3` after `Repo.transaction` commits
  (GF-703) — until every Broadway batch is committed and visible.

  Pure module: no GenServer, no spawn_link. `receive` runs in the caller
  process (HTTP request, test process). Subscribes BEFORE ingest so no
  broadcast is missed; unsubscribes in `after` (even on timeout / raise).
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias SpanChain.{Cassette, Ledger, Repo}
  alias SpanChain.Evals.Comparator
  alias SpanChain.Ingestion.{SessionGenServer, SessionSupervisor}

  @default_timeout_ms 15_000

  @type result :: %{
          run_id: String.t(),
          span_count: non_neg_integer(),
          hash_valid: boolean(),
          diff: [map()]
        }

  @spec replay(Cassette.t(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def replay(%Cassette{} = cassette, opts \\ []) do
    new_run_id = opts[:run_id] || generate_run_id(cassette.cassette_id)
    spans = cassette.snapshot
    expected = length(spans)
    timeout = opts[:timeout] || @default_timeout_ms
    # GF-725: absolute monotonic deadline místo relativního timeout — rekurzivní
    # `wait_for_all_spans` jinak resetoval timer při každém broadcastu, takže
    # cassette s N batchy mohla blokovat HTTP request až N × timeout místo
    # garantovaného `timeout` celkem.
    deadline = System.monotonic_time(:millisecond) + timeout
    topic = "run:#{new_run_id}"

    Phoenix.PubSub.subscribe(SpanChain.PubSub, topic)

    try do
      with {:ok, _pid} <- SessionSupervisor.ensure_session(new_run_id),
           {:ok, _n} <- SessionGenServer.ingest_spans(new_run_id, spans),
           {:ok, db_count} <- wait_for_all_spans(new_run_id, expected, deadline) do
        hash_valid = match?({:ok, _}, Ledger.verify_ledger(new_run_id))

        diff =
          case Comparator.compare(cassette.run_id, new_run_id) do
            {:ok, %{"differences" => d}} -> d
            {:error, _reason} -> []
          end

        {:ok, %{run_id: new_run_id, span_count: db_count, hash_valid: hash_valid, diff: diff}}
      end
    after
      Phoenix.PubSub.unsubscribe(SpanChain.PubSub, topic)
    end
  end

  @doc false
  # Test seam (GF-725): viditelnost zvýšena z `defp` na `def` aby unit test mohl
  # přímo ověřit deadline pattern bez konstrukce 3+ batch cassety s mockovaným
  # DB timingem. NEpoužívat z produkčního kódu — caller je výhradně `replay/2`.
  #
  # Empty cassette short-circuit: 0 spans → 0 broadcasts.
  def wait_for_all_spans(_run_id, 0, _deadline), do: {:ok, 0}

  def wait_for_all_spans(run_id, expected, deadline) do
    timeout = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:spans_flushed, ^run_id} ->
        db_count = count_rows(run_id)

        if db_count >= expected do
          {:ok, db_count}
        else
          wait_for_all_spans(run_id, expected, deadline)
        end
    after
      timeout -> {:error, :timeout}
    end
  end

  defp count_rows(run_id) do
    Repo.aggregate(from(l in Ledger, where: l.run_id == ^run_id), :count, :run_id)
  end

  # GF-726: Pre-fix používal VM-local positive integer counter, který se po
  # BEAM restartu resetuje od malého čísla → kolize s historickými replay
  # `run_id` v DB přes `(run_id, epoch_id, seq)` unique index.
  # `Ecto.UUID.generate/0` (UUID v4) je globally unique nezávisle na VM
  # lifecycle; Ecto je už v deps, takže žádná nová závislost.
  defp generate_run_id(cassette_id) do
    "replay-#{cassette_id}-#{Ecto.UUID.generate()}"
  end
end
