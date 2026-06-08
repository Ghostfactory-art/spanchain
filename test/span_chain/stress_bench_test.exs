defmodule SpanChain.StressBenchTest do
  @moduledoc """
  GF-773/GF-772 stress benchmark — a smoke check of the bench path.

  `@moduletag :stress` keeps this module OUT of the default `mix test` suite
  (`ExUnit.configure(exclude: [:stress])` in `test_helper.exs`). Run it manually:

      mix test test/span_chain/stress_bench_test.exs --include stress --timeout 120000

  Real numbers for the landing page are NOT measured here — the test env runs in the Sandbox
  (savepoint commits without fsync = overstated throughput, batch_timeout 50ms).
  The published numbers come from the DEV env (real WAL DB, 1000ms timeout):

      mix run -e "SpanChain.StressTest.bench_report()"

  This test only verifies that the bench functions don't crash on a small run.
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
