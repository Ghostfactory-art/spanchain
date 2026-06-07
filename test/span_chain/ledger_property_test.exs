defmodule SpanChain.LedgerPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SpanChain.Ledger

  # In-memory chain builder — žádný DB call. Postaví validní hash-chain
  # z libovolné sekvence payloadů; každý entry navazuje na předchozí přes
  # prev_hash. Vrací list entry map (ne struct), shodné s `Ledger.build_entry/7`.
  defp build_chain(payloads) do
    {entries, _last_hash} =
      Enum.reduce(payloads, {[], nil}, fn payload, {acc, prev_hash} ->
        seq = length(acc)
        entry = Ledger.build_entry("prop-run", 0, seq, prev_hash, "span", payload, nil)
        {acc ++ [entry], entry.hash}
      end)

    entries
  end

  property "Property D: tamper na libovolný payload zlomí hash na dané pozici" do
    check all(
            payloads <-
              list_of(
                map_of(
                  string(:alphanumeric, max_length: 4),
                  string(:alphanumeric, max_length: 8),
                  max_length: 4
                ),
                min_length: 2,
                max_length: 10
              ),
            tamper_idx <- integer(0..9)
          ) do
      idx = rem(tamper_idx, length(payloads))
      entries = build_chain(payloads)
      original = Enum.at(entries, idx)

      tampered_hash =
        Ledger.compute_hash(
          original.seq,
          original.prev_hash,
          original.event_type,
          %{"tampered" => "payload"},
          original.parent_span_id,
          original.run_id,
          original.epoch_id
        )

      assert tampered_hash != original.hash,
             "Tampered hash should differ at index #{idx} (seq=#{original.seq})"
    end
  end

  property "Property D2: identický payload v identické pozici → identický hash (determinismus chainu)" do
    check all(
            payloads <-
              list_of(
                map_of(
                  string(:alphanumeric, max_length: 4),
                  string(:alphanumeric, max_length: 8),
                  max_length: 4
                ),
                min_length: 1,
                max_length: 8
              )
          ) do
      chain_a = build_chain(payloads)
      chain_b = build_chain(payloads)

      hashes_a = Enum.map(chain_a, & &1.hash)
      hashes_b = Enum.map(chain_b, & &1.hash)

      assert hashes_a == hashes_b
    end
  end
end
