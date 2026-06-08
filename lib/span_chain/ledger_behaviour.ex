defmodule SpanChain.Ledger.Behaviour do
  @moduledoc """
  Callback contract for Ledger persistence — a DI seam for testing the Pipeline
  without a live DB.

  The real `SpanChain.Ledger` implements this behaviour and returns the raw Ecto
  `insert_all/3` tuple `{n, nil | [...]}`. Failure is signaled by a raise (Ecto
  driver behavior). Test stubs follow the same convention — they simulate a DB error
  via `raise`, not via `{:error, _}` — so that `Pipeline.with_retry/3` (which
  catches the raise → `{:error, reason}` → retry) behaves identically for the real
  module and the stub.
  """

  @callback insert_batch([map()]) :: {non_neg_integer(), nil | [term()]}
end
