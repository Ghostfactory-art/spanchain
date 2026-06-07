defmodule SpanChain.Cassettes.ReplayerTest do
  @moduledoc """
  Replayer unit tests (GF-712). Pokrývá: payload-first precision round-trip,
  multi-batch wait synchronizaci (cassette > batch_size 50), hash chain
  validity po replay, a `{:error, :timeout}` cestu.
  """

  use SpanChain.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias SpanChain.{Cassette, Cassettes, Ledger, Repo}
  alias SpanChain.Cassettes.Replayer
  alias SpanChain.Ingestion.{SessionGenServer, SessionSupervisor}

  defp fresh_run_id(prefix \\ "rpl"),
    do: "#{prefix}-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp fresh_cassette_id,
    do: "rpl-cassette-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp span_map(i, opts \\ []) do
    base = ~U[2026-05-17 12:00:00.000Z]
    started = DateTime.add(base, i, :millisecond)
    ended = DateTime.add(started, 5, :millisecond)

    %{
      "span_id" => "s-#{i}",
      "name" => Keyword.get(opts, :name, "step_#{i}"),
      "started_at" => DateTime.to_iso8601(started),
      "ended_at" => DateTime.to_iso8601(ended),
      "attributes" => %{}
    }
  end

  # GF-781/GF-782: čekáme na committed COUNT, ne na odhadnutý počet batchů. Broadway
  # je demand-driven — pod zátěží může 120 spanů rozdělit na > ceil(N/50) batchů, takže
  # počítání batchů přes in-transaction telemetry vracelo brzo a `Cassettes.record`
  # snapshotnul < N řádků → flaky `length(snapshot) == N`. Subscribe PŘED ingest +
  # symetrický unsubscribe; topic je distinktní od replay/2 `run:#{new_run_id}`.
  defp record_cassette(run_id, spans, cassette_id) do
    Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")
    {:ok, _pid} = SessionSupervisor.ensure_session(run_id)
    {:ok, _n} = SessionGenServer.ingest_spans(run_id, spans)
    :ok = wait_for_committed(run_id, length(spans))
    Phoenix.PubSub.unsubscribe(SpanChain.PubSub, "run:#{run_id}")

    {:ok, cassette} = Cassettes.record(run_id, cassette_id: cassette_id)
    cassette
  end

  # Loop na post-commit `{:spans_flushed}` (GF-703) dokud count >= expected. Stejný
  # vzor jako Replayer.wait_for_all_spans/3 a session_gen_server_test.wait_for_all_committed.
  defp wait_for_committed(run_id, expected, timeout_ms \\ 10_000) do
    if count_committed(run_id) >= expected do
      :ok
    else
      receive do
        {:spans_flushed, ^run_id} -> wait_for_committed(run_id, expected, timeout_ms)
      after
        timeout_ms ->
          flunk("only #{count_committed(run_id)}/#{expected} committed for #{run_id}")
      end
    end
  end

  defp count_committed(run_id),
    do: Repo.aggregate(from(l in Ledger, where: l.run_id == ^run_id), :count, :run_id)

  describe "replay/2 — payload-first precision" do
    test "sub-second started_at/ended_at survive snapshot round-trip" do
      run_id = fresh_run_id("prec")
      spans = [span_map(0)]

      cassette = record_cassette(run_id, spans, fresh_cassette_id())

      [snapshot_span] = cassette.snapshot
      assert snapshot_span["started_at"] =~ ".000"
      assert snapshot_span["ended_at"] =~ ".005"

      assert {:ok, %{run_id: replayed, span_count: 1, hash_valid: true}} =
               Replayer.replay(cassette)

      [%{payload: replayed_payload}] = from_ledger(replayed)
      assert replayed_payload["started_at"] =~ ".000"
      assert replayed_payload["ended_at"] =~ ".005"
    end
  end

  describe "replay/2 — multi-batch synchronization" do
    @tag timeout: 30_000
    test "cassette with 120 spans (3 batches) returns only after all rows committed" do
      run_id = fresh_run_id("multi")
      spans = Enum.map(0..119, &span_map/1)

      cassette = record_cassette(run_id, spans, fresh_cassette_id())
      assert length(cassette.snapshot) == 120

      assert {:ok, %{run_id: replayed, span_count: 120, hash_valid: true, diff: []}} =
               Replayer.replay(cassette)

      assert Repo.aggregate(
               from(l in Ledger, where: l.run_id == ^replayed),
               :count,
               :run_id
             ) == 120

      assert {:ok, 120} = Ledger.verify_ledger(replayed)
    end
  end

  describe "replay/2 — timeout path" do
    test "wait_for_all_spans returns :timeout when no broadcast arrives in window" do
      # Snapshot has 1 span; passing timeout=1ms is below test env Broadway
      # batch_timeout (50ms), guaranteeing the receive `after` fires before
      # any broadcast can arrive → deterministic :timeout.
      run_id = "orphan-" <> fresh_run_id()

      cassette = %Cassette{
        cassette_id: "timeout-" <> fresh_cassette_id(),
        run_id: "src-" <> fresh_run_id(),
        snapshot: [span_map(0)],
        recorded_at: DateTime.utc_now()
      }

      assert {:error, :timeout} = Replayer.replay(cassette, run_id: run_id, timeout: 1)

      # Subscribe AFTER Replayer returns — its after-block already unsubscribed,
      # and Registry.unregister/2 wipes all of the caller pid's entries, so a
      # pre-call subscribe would be nuked. Waiting for the post-commit broadcast
      # (fires after Repo.transaction commits, per GF-703) lets Broadway release
      # its DB connection before the test exits — silences the sandbox-race
      # `Exqlite.Connection owner exited` ERROR log.
      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")
      on_exit(fn -> Phoenix.PubSub.unsubscribe(SpanChain.PubSub, "run:#{run_id}") end)

      assert_receive {:spans_flushed, ^run_id}, 5_000
    end
  end

  describe "replay/2 — hash chain validity" do
    test "verify_ledger returns {:ok, count} for replayed run" do
      run_id = fresh_run_id("hash")
      spans = Enum.map(0..3, &span_map/1)

      cassette = record_cassette(run_id, spans, fresh_cassette_id())

      assert {:ok, %{run_id: replayed, hash_valid: true}} = Replayer.replay(cassette)
      assert {:ok, 4} = Ledger.verify_ledger(replayed)
    end
  end

  describe "wait_for_all_spans/3 — GF-725 absolute deadline" do
    # Pre-fix: 3rd argument byl relativní timeout, který se předával beze změny
    # do rekurzivního volání → každý {:spans_flushed} broadcast resetoval timer
    # → cassette s 10 batchy mohla čekat 10× timeout. Test ověří že total elapsed
    # NEPŘEKROČÍ původní deadline ani když dorazí několik broadcastů.
    test "celkový elapsed je bounded by initial deadline napříč recursi" do
      # Synthetic run_id — žádné rows v DB, count_rows vždy vrátí 0.
      orphan = "orphan-" <> fresh_run_id("dl")
      deadline_ms = 150

      # Pošli si pre-emptivně 5 broadcastů. Každý projde matchem
      # `{:spans_flushed, ^run_id}`, count_rows=0 < expected=10 → recurse.
      # Po vyčerpání mailboxu funkce blokuje na `after timeout` — total elapsed
      # MUSÍ zůstat v rámci deadline_ms (s tolerancí na overhead).
      Enum.each(1..5, fn _ -> send(self(), {:spans_flushed, orphan}) end)

      deadline = System.monotonic_time(:millisecond) + deadline_ms
      t0 = System.monotonic_time(:millisecond)

      assert {:error, :timeout} = Replayer.wait_for_all_spans(orphan, 10, deadline)

      elapsed = System.monotonic_time(:millisecond) - t0

      # Pre-fix by elapsed bylo ~5 × deadline_ms (~750ms) — každý broadcast
      # resetoval timer. Post-fix musí být < ~1.5× deadline (overhead na 5
      # rekurzi + final receive blok). 250ms ceiling drží daleko od pre-fix worst case.
      assert elapsed < 250,
             "elapsed=#{elapsed}ms překročilo deadline=#{deadline_ms}ms (pre-fix would be ~750ms)"
    end
  end

  describe "replay/2 — GF-726 UUID-based replay_id" do
    test "replay generuje UUID-based run_id (žádný System.unique_integer)" do
      run_id = fresh_run_id("uuid-src")
      spans = [span_map(0)]
      cassette = record_cassette(run_id, spans, fresh_cassette_id())

      {:ok, %{run_id: replayed_1}} = Replayer.replay(cassette)
      {:ok, %{run_id: replayed_2}} = Replayer.replay(cassette)

      prefix = "replay-#{cassette.cassette_id}-"

      assert String.starts_with?(replayed_1, prefix)
      assert String.starts_with?(replayed_2, prefix)

      # UUID část za prefixem musí být validní UUID (36 chars s pomlčkami).
      uuid_1 = String.replace_prefix(replayed_1, prefix, "")
      uuid_2 = String.replace_prefix(replayed_2, prefix, "")
      assert {:ok, ^uuid_1} = Ecto.UUID.cast(uuid_1)
      assert {:ok, ^uuid_2} = Ecto.UUID.cast(uuid_2)

      # Dva po sobě jdoucí replaye musí mít RŮZNÉ run_id (kolize check).
      refute replayed_1 == replayed_2
    end
  end

  defp from_ledger(run_id) do
    from(l in Ledger, where: l.run_id == ^run_id, order_by: [asc: l.seq])
    |> Repo.all()
  end
end
