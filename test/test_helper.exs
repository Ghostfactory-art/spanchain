Ecto.Adapters.SQL.Sandbox.mode(SpanChain.Repo, :manual)
ExUnit.start()

# GF-773: stress/bench testy se NEspouští v default suite (timeout v CI). Spusť je
# manuálně přes `mix test --include stress` nebo reálná dev-env čísla přes
# `mix run -e "SpanChain.StressTest.bench_report()"`.
ExUnit.configure(exclude: [:stress])
