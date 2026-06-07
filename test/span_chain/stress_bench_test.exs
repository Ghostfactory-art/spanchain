defmodule SpanChain.StressBenchTest do
  @moduledoc """
  GF-773/GF-772 stress benchmark — smoke ověření bench cesty.

  `@moduletag :stress` drží tenhle modul MIMO default `mix test` suite
  (`ExUnit.configure(exclude: [:stress])` v `test_helper.exs`). Spusť ručně:

      mix test test/span_chain/stress_bench_test.exs --include stress --timeout 120000

  Reálná čísla pro landing page se NEMĚŘÍ tady — test env běží v Sandboxu
  (savepoint commity bez fsync = nadhodnocený throughput, batch_timeout 50ms).
  Publikovaná čísla pocházejí z DEV env (reálná WAL DB, 1000ms timeout):

      mix run -e "SpanChain.StressTest.bench_report()"

  Tenhle test jen ověří, že bench funkce nepadají na malém běhu.
  """
  use SpanChain.DataCase, async: false

  @moduletag :stress

  alias SpanChain.StressTest

  test "throughput bench runs sleep-free without crashing (small)" do
    result = StressTest.bench_throughput(10, 10)

    assert result.total_spans == 100
    assert result.spans_per_second > 0
    assert result.success_rate > 0
  end

  test "SGS memory probe returns a positive KB figure" do
    assert StressTest.bench_memory() > 0
  end

  test "latency percentiles computed over a small sample" do
    lat = StressTest.bench_latency(20)

    assert lat.n > 0
    assert lat.p99 >= lat.p50
  end
end
