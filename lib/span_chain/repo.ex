defmodule SpanChain.Repo do
  @moduledoc "Ecto Repo nad Postgres — persistence pro hash-chain Ledger (GF-704)."

  use Ecto.Repo,
    otp_app: :span_chain,
    adapter: Ecto.Adapters.Postgres
end
