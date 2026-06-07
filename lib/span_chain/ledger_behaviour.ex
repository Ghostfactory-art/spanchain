defmodule SpanChain.Ledger.Behaviour do
  @moduledoc """
  Callback contract for Ledger persistence — DI seam pro Pipeline testování
  bez živé DB.

  Reálný `SpanChain.Ledger` implementuje tento behaviour a vrací raw Ecto
  `insert_all/3` tuple `{n, nil | [...]}`. Selhání signalizuje raise (Ecto
  driver chování). Test stubs následují stejnou konvenci — simulují DB chybu
  přes `raise`, ne přes `{:error, _}` — aby `Pipeline.with_retry/3` (které
  catchuje raise → `{:error, reason}` → retry) fungovalo identicky pro real
  i stub.
  """

  @callback insert_batch([map()]) :: {non_neg_integer(), nil | [term()]}
end
