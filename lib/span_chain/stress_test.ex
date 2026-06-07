defmodule SpanChain.StressTest do
  @moduledoc """
  Load generator pro GhostFactory ingestion pipeline.

  Spustí `agents` paralelních agentů (každý jako vlastní `Task` + `Harness`),
  každý agent vytvoří jeden vnější `agent_run` span obalující `spans_per_agent`
  vnitřních `llm_call` spanů. Každý 10. llm_call simuluje chybu (`raise`) —
  Harness ji uloží jako error span a smyčka pokračuje, abychom garantovali
  `agents * (spans_per_agent + 1)` celkových řádků v Ledgeru.

  ## Example

      iex> SpanChain.StressTest.run(agents: 10, spans_per_agent: 5)
      %{
        agents: 10,
        total_spans: 50,
        duration_ms: 184,
        spans_per_second: 271.7,
        db_rows_written: 60,
        error_spans: 0,
        abandoned_spans: 0
      }

  Pro stress run cca 5000 spanů:

      mix run -e "SpanChain.StressTest.run(agents: 100, spans_per_agent: 50)"
  """

  require Logger
  import Ecto.Query

  alias SpanChain.{Harness, Ledger, Repo}
  alias SpanChain.Ingestion.{SessionGenServer, SessionSupervisor}

  @type metrics :: %{
          agents: non_neg_integer(),
          total_spans: non_neg_integer(),
          duration_ms: non_neg_integer(),
          spans_per_second: float(),
          db_rows_written: non_neg_integer(),
          error_spans: non_neg_integer(),
          abandoned_spans: non_neg_integer()
        }

  @spec run(keyword()) :: metrics()
  def run(opts \\ []) do
    agents = Keyword.get(opts, :agents, 10)
    spans_per_agent = Keyword.get(opts, :spans_per_agent, 5)
    prefix = "stress-#{System.system_time(:millisecond)}-"

    Logger.info(
      "[StressTest] starting agents=#{agents} spans_per_agent=#{spans_per_agent} prefix=#{prefix}"
    )

    started_mono = System.monotonic_time(:millisecond)

    _run_ids =
      1..agents
      |> Task.async_stream(
        fn index -> run_agent(prefix <> Integer.to_string(index), index, spans_per_agent) end,
        max_concurrency: agents,
        timeout: 60_000,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.flat_map(fn
        {:ok, run_id} ->
          [run_id]

        {:exit, reason} ->
          Logger.warning("[StressTest] agent task exited: #{inspect(reason)}")
          []
      end)

    expected_total = agents * (spans_per_agent + 1)
    flush_all(prefix, expected_total)

    duration_ms = System.monotonic_time(:millisecond) - started_mono
    metrics = collect_metrics(prefix, agents, spans_per_agent, duration_ms)

    Logger.info(
      "[StressTest] done agents=#{metrics.agents} total_spans=#{metrics.total_spans} " <>
        "duration_ms=#{metrics.duration_ms} spans_per_second=#{metrics.spans_per_second} " <>
        "db_rows_written=#{metrics.db_rows_written} error_spans=#{metrics.error_spans} " <>
        "abandoned_spans=#{metrics.abandoned_spans}"
    )

    metrics
  end

  # --------------------------------------------------------------------------
  # Per-agent task
  # --------------------------------------------------------------------------

  defp run_agent(run_id, index, spans_per_agent) do
    {:ok, h} = Harness.start_link(run_id: run_id)

    try do
      Harness.with_span(h, "agent_run", %{agent: index}, fn ->
        for i <- 1..spans_per_agent do
          try do
            Harness.with_span(h, "llm_call", %{call: i}, fn ->
              Process.sleep(Enum.random(1..5))
              if rem(i, 10) == 0, do: raise("simulated_error_#{i}")
              "result_#{i}"
            end)
          rescue
            _ -> :error_handled
          end
        end
      end)
    after
      Harness.stop(h)
    end

    run_id
  end

  # --------------------------------------------------------------------------
  # Post-run flush + metrics
  # --------------------------------------------------------------------------

  # GF-667: SGS.flush_now neexistuje (slim refactor). Broadway flush je async
  # s batch_timeout 1s. Místo synchronního flush polluje Repo aggregate count
  # pro tento `prefix` until reaches `expected_total` (nebo 30s timeout).
  defp flush_all(prefix, expected_total) do
    pattern = prefix <> "%"
    deadline = System.monotonic_time(:millisecond) + 30_000
    wait_for_count(pattern, expected_total, deadline)
  end

  defp wait_for_count(pattern, expected, deadline) do
    count =
      Repo.aggregate(
        from(l in Ledger, where: like(l.run_id, ^pattern)),
        :count,
        :id
      )

    cond do
      count >= expected ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        Logger.warning("[StressTest] flush timeout — got #{count}/#{expected}")
        :timeout

      true ->
        Process.sleep(100)
        wait_for_count(pattern, expected, deadline)
    end
  end

  defp collect_metrics(prefix, agents, spans_per_agent, duration_ms) do
    pattern = prefix <> "%"

    rows =
      from(l in Ledger, where: like(l.run_id, ^pattern))
      |> Repo.all()

    db_rows_written = length(rows)

    error_spans =
      Enum.count(rows, fn r ->
        get_in(r.payload, ["attributes", "status"]) == "error"
      end)

    abandoned_spans =
      Enum.count(rows, fn r ->
        get_in(r.payload, ["attributes", "status"]) == "abandoned"
      end)

    total_spans = agents * spans_per_agent

    spans_per_second =
      if duration_ms > 0,
        do: Float.round(total_spans * 1000 / duration_ms, 1),
        else: 0.0

    %{
      agents: agents,
      total_spans: total_spans,
      duration_ms: duration_ms,
      spans_per_second: spans_per_second,
      db_rows_written: db_rows_written,
      error_spans: error_spans,
      abandoned_spans: abandoned_spans
    }
  end

  # ==========================================================================
  # GF-773 / GF-772 — benchmark sada pro reálná LP čísla.
  #
  # Měří se v DEV env (reálná SQLite WAL DB, reálné per-batch commity,
  # batch_timeout 1000ms) — NE v test env sandboxu (savepoint "commity" bez
  # fsync = nadhodnocený throughput). Drží se původní baseline metodika
  # (elapsed = od startu ingestu po commit všech řádků). Pohání SGS přímo —
  # žádný Harness `Process.sleep` mezi spany (GF-773 §1).
  #
  # Spuštění (reálná čísla pro landing page):
  #     mix run -e "SpanChain.StressTest.bench_report()"
  # ==========================================================================

  @buffer_registry SpanChain.Ingestion.BufferRegistry

  @doc "Celá benchmark sada (GF-773 §1–4 + GF-772 §5) + §6 summary blok."
  def bench_report do
    date = Date.utc_today() |> Date.to_iso8601()

    a = bench_throughput(100, 100)
    b = bench_throughput(500, 100)
    c = bench_throughput(1000, 50)
    mem_kb = bench_memory()
    lat = bench_latency(200)
    flood = bench_flood()

    print_summary(date, a, b, c, mem_kb, lat, flood)

    %{throughput: a, scalability: [a, b, c], memory_kb: mem_kb, latency: lat, flood: flood}
  end

  @doc "Sleep-free throughput: `agents` paralelních runů × `spans_per_agent` spanů."
  def bench_throughput(agents, spans_per_agent) do
    prefix = unique_prefix("bench")
    expected = agents * spans_per_agent
    spans = build_spans(spans_per_agent)

    started = System.monotonic_time(:millisecond)
    ingest_load(agents, spans, prefix)
    flush = wait_for_count(prefix <> "%", expected, System.monotonic_time(:millisecond) + 120_000)
    elapsed_ms = System.monotonic_time(:millisecond) - started

    db_count = count_rows(prefix <> "%")

    %{
      agents: agents,
      spans_per_agent: spans_per_agent,
      total_spans: expected,
      elapsed_ms: elapsed_ms,
      spans_per_second: per_sec(expected, elapsed_ms),
      success_rate: Float.round(min(db_count, expected) * 100 / expected, 1),
      flush: flush
    }
  end

  @doc "SGS memory footprint jedné session přes `process_info(:memory)` (GF-773 §3)."
  def bench_memory do
    run_id = unique_prefix("mem") <> "1"
    {:ok, pid} = SessionSupervisor.ensure_session(run_id)
    {:ok, _} = SessionGenServer.ingest_spans(run_id, build_spans(10))
    {:memory, bytes} = :erlang.process_info(pid, :memory)
    div(bytes, 1024)
  end

  @doc "End-to-end latence ingest → `{:spans_flushed}` pro `samples` souběžných 1-span runů (GF-773 §4)."
  def bench_latency(samples) do
    prefix = unique_prefix("lat")

    micros =
      1..samples
      |> Task.async_stream(
        fn i ->
          run_id = prefix <> Integer.to_string(i)
          Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")
          {:ok, _} = SessionSupervisor.ensure_session(run_id)
          t0 = System.monotonic_time(:microsecond)

          {:ok, _} =
            SessionGenServer.ingest_spans(run_id, [%{"span_id" => "s1", "name" => "llm_call"}])

          receive do
            {:spans_flushed, ^run_id} -> System.monotonic_time(:microsecond) - t0
          after
            30_000 -> nil
          end
        end,
        max_concurrency: samples,
        timeout: 60_000,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.flat_map(fn
        {:ok, us} when is_integer(us) -> [us]
        _ -> []
      end)

    percentiles_ms(micros)
  end

  @doc "GF-772 flood: 50 × 200 spanů (10k) bez sleep; peak buffer fill + data loss + recovery."
  def bench_flood do
    prefix = unique_prefix("flood")
    agents = 50
    spans_per = 200
    expected = agents * spans_per
    spans = build_spans(spans_per)

    {sampler, sref} = start_queue_sampler()
    ingest_load(agents, spans, prefix)
    flush = wait_for_count(prefix <> "%", expected, System.monotonic_time(:millisecond) + 120_000)
    peak = stop_queue_sampler(sampler, sref)

    db_count = count_rows(prefix <> "%")

    # Recovery: po 5s zkus malý ingest — projde celou pipeline bez degradace?
    Process.sleep(5_000)

    %{
      total_spans: expected,
      db_count: db_count,
      data_loss: max(expected - db_count, 0),
      peak_queue: peak,
      flush: flush,
      post_health: flood_health_check()
    }
  end

  # --------------------------------------------------------------------------
  # Bench interní helpery
  # --------------------------------------------------------------------------

  # Paralelní ingest přímo přes SGS (bez Harness/sleep). Drainuje stream pro
  # side-effekt; async_stream yielduje {:exit, _} pro spadlé tasky (neraisne).
  defp ingest_load(agents, spans, prefix) do
    1..agents
    |> Task.async_stream(
      fn i ->
        run_id = prefix <> Integer.to_string(i)
        {:ok, _} = SessionSupervisor.ensure_session(run_id)
        {:ok, _} = SessionGenServer.ingest_spans(run_id, spans)
        run_id
      end,
      max_concurrency: agents,
      timeout: 120_000,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Stream.run()
  end

  defp build_spans(n) do
    for i <- 1..n do
      %{"span_id" => "s#{i}", "name" => "llm_call", "attributes" => %{"call" => i}}
    end
  end

  defp count_rows(pattern) do
    Repo.aggregate(from(l in Ledger, where: like(l.run_id, ^pattern)), :count, :id)
  end

  defp per_sec(_total, ms) when ms <= 0, do: 0.0
  defp per_sec(total, ms), do: Float.round(total * 1000 / ms, 1)

  defp unique_prefix(tag), do: "#{tag}-#{System.unique_integer([:positive])}-"

  defp percentiles_ms([]), do: %{p50: 0.0, p95: 0.0, p99: 0.0, n: 0}

  defp percentiles_ms(micros) do
    sorted = Enum.sort(micros)

    %{
      p50: Float.round(pct(sorted, 0.50) / 1000, 1),
      p95: Float.round(pct(sorted, 0.95) / 1000, 1),
      p99: Float.round(pct(sorted, 0.99) / 1000, 1),
      n: length(sorted)
    }
  end

  defp pct(sorted, q), do: Enum.at(sorted, max(round(q * length(sorted)) - 1, 0))

  # Background sampler — periodicky čte hloubku in-memory :queue v BufferProducer
  # (přes BufferRegistry singleton, NE Process.whereis — producer běží pod
  # interním Broadway name) a drží pozorované maximum.
  defp start_queue_sampler do
    ref = make_ref()
    parent = self()
    pid = spawn_link(fn -> sampler_loop(parent, ref, 0) end)
    {pid, ref}
  end

  defp sampler_loop(parent, ref, peak) do
    receive do
      {:stop, ^ref} -> send(parent, {:peak, ref, peak})
    after
      2 -> sampler_loop(parent, ref, max(peak, current_queue_len()))
    end
  end

  defp stop_queue_sampler(pid, ref) do
    send(pid, {:stop, ref})

    receive do
      {:peak, ^ref, peak} -> peak
    after
      5_000 -> :unknown
    end
  end

  defp current_queue_len do
    case Registry.lookup(@buffer_registry, :singleton) do
      [{pid, _}] ->
        try do
          :queue.len(:sys.get_state(pid, 1_000).queue)
        catch
          _, _ -> 0
        end

      _ ->
        0
    end
  end

  defp flood_health_check do
    run_id = unique_prefix("health") <> "1"
    Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")
    {:ok, _} = SessionSupervisor.ensure_session(run_id)
    {:ok, _} = SessionGenServer.ingest_spans(run_id, [%{"span_id" => "h1", "name" => "health"}])

    receive do
      {:spans_flushed, ^run_id} -> :ok
    after
      10_000 -> :degraded
    end
  end

  defp print_summary(date, a, b, c, mem_kb, lat, flood) do
    sessions_per_min = round(a.agents * 60_000 / max(a.elapsed_ms, 1))

    IO.puts("""

    === GhostFactory Span Chain — Stress Test Results ===
    Date: #{date}

    [Throughput — no sleep]
      100 agents × 100 spans: #{commafy(a.spans_per_second)} spans/s (elapsed: #{a.elapsed_ms}ms)

    [Scalability]
      100 agents × 100 spans: #{commafy(a.spans_per_second)} spans/s
      500 agents × 100 spans: #{commafy(b.spans_per_second)} spans/s
      1000 agents ×  50 spans: #{commafy(c.spans_per_second)} spans/s

    [Memory]
      SGS per session: ~#{mem_kb} KB

    [Latency]
      p50: #{lat.p50}ms  p95: #{lat.p95}ms  p99: #{lat.p99}ms

    [Broadway back-pressure]
      10k span flood: peak buffer fill = #{flood.peak_queue}
      Post-flood health: #{if flood.post_health == :ok, do: "OK", else: "DEGRADED"}
      Data loss: #{if flood.data_loss == 0, do: "none", else: "#{flood.data_loss} spans"}

    === Landing Page Copy Candidates ===
      "Handles #{commafy(sessions_per_min)}+ agent sessions per minute"
      "p99 latency under #{ceil_ms(lat.p99)}ms"
      "~#{mem_kb} KB memory per session"
    """)
  end

  defp commafy(n) when is_float(n), do: commafy(round(n))

  defp commafy(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp ceil_ms(x), do: trunc(Float.ceil(x))
end
