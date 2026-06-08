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
    # GF-725: an absolute monotonic deadline instead of a relative timeout — the recursive
    # `wait_for_all_spans` otherwise reset the timer on every broadcast, so a
    # cassette with N batches could block the HTTP request up to N × timeout instead of
    # the guaranteed `timeout` total.
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
  # Test seam (GF-725): visibility raised from `defp` to `def` so a unit test can
  # directly verify the deadline pattern without constructing a 3+ batch cassette with mocked
  # DB timing. Do NOT use from production code — the only caller is `replay/2`.
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

  # GF-726: The pre-fix used a VM-local positive integer counter, which after a
  # BEAM restart resets from a small number → collisions with historical replay
  # `run_id`s in the DB via the `(run_id, epoch_id, seq)` unique index.
  # `Ecto.UUID.generate/0` (UUID v4) is globally unique regardless of VM
  # lifecycle; Ecto is already in deps, so no new dependency.
  defp generate_run_id(cassette_id) do
    "replay-#{cassette_id}-#{Ecto.UUID.generate()}"
  end
end
