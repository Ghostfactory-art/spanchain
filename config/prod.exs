import Config

config :span_chain, SpanChain.Repo,
  database: System.get_env("GF_DB_PATH", "priv/span_chain_prod.db"),
  pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))

config :logger, level: :info
