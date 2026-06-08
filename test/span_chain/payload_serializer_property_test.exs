defmodule SpanChain.PayloadSerializerPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SpanChain.PayloadSerializer

  # CRITICAL: string keys only — atom keys would cause a false positive
  # in the losslessness test (Jason.decode! always returns string keys, so
  # `%{k: 1}` after a roundtrip == `%{"k" => 1}`, which fails the comparison not
  # because of a bug, but because of the key type in the generator).
  defp json_value(depth \\ 0) do
    leaves =
      one_of([
        string(:alphanumeric, max_length: 8),
        integer(),
        boolean(),
        constant(nil)
      ])

    if depth >= 3 do
      leaves
    else
      one_of([
        leaves,
        map_of(string(:alphanumeric, max_length: 4), json_value(depth + 1), max_length: 5),
        list_of(json_value(depth + 1), max_length: 5)
      ])
    end
  end

  property "canonical_encode/1 never crashes on valid JSON-like input" do
    check all(data <- json_value()) do
      assert is_binary(PayloadSerializer.canonical_encode(data))
    end
  end

  property "canonical_encode/1 produces valid JSON (lossless roundtrip)" do
    check all(data <- json_value()) do
      encoded = PayloadSerializer.canonical_encode(data)
      decoded = Jason.decode!(encoded)
      assert decoded == data
    end
  end

  property "canonical_encode/1 is deterministic for the same map" do
    check all(data <- map_of(string(:alphanumeric, max_length: 4), json_value(1), max_length: 8)) do
      assert PayloadSerializer.canonical_encode(data) ==
               PayloadSerializer.canonical_encode(data)
    end
  end

  property "canonical_encode/1 is independent of insertion order (the key GF-654 invariant)" do
    # Note: we generate the map directly (not a list of {k, v}) — `list_of(tuple(...))` may
    # produce duplicate keys, where `Map.new` picks LIFO, so forward vs reversed
    # would yield semantically different maps and the test would report a false positive. A map from StreamData
    # has no duplicate keys by construction.
    check all(data <- map_of(string(:alphanumeric, max_length: 4), json_value(1), max_length: 8)) do
      reversed = data |> Map.to_list() |> Enum.reverse() |> Map.new()

      assert PayloadSerializer.canonical_encode(data) ==
               PayloadSerializer.canonical_encode(reversed)
    end
  end
end
