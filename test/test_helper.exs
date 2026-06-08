Ecto.Adapters.SQL.Sandbox.mode(SpanChain.Repo, :manual)
ExUnit.start()

# GF-773: stress/bench tests do NOT run in the default suite (timeout in CI). Run them
# manually via `mix test --include stress`, or real dev-env numbers via
# `mix run -e "SpanChain.StressTest.bench_report()"`.
ExUnit.configure(exclude: [:stress])
