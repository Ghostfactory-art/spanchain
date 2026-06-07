defmodule SpanChain.PayloadSerializerPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SpanChain.PayloadSerializer

  # KRITICKÉ: pouze string keys — atom keys by způsobily false positive
  # v losslessness testu (Jason.decode! vždy vrací string keys, takže
  # `%{k: 1}` po roundtripu == `%{"k" => 1}`, což porovnání selže nikoli
  # kvůli bugu, ale kvůli typu klíče v generátoru).
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

  property "canonical_encode/1 nikdy nespadne na valid JSON-like vstupu" do
    check all(data <- json_value()) do
      assert is_binary(PayloadSerializer.canonical_encode(data))
    end
  end

  property "canonical_encode/1 produkuje validní JSON (lossless roundtrip)" do
    check all(data <- json_value()) do
      encoded = PayloadSerializer.canonical_encode(data)
      decoded = Jason.decode!(encoded)
      assert decoded == data
    end
  end

  property "canonical_encode/1 je deterministický pro stejnou mapu" do
    check all(data <- map_of(string(:alphanumeric, max_length: 4), json_value(1), max_length: 8)) do
      assert PayloadSerializer.canonical_encode(data) ==
               PayloadSerializer.canonical_encode(data)
    end
  end

  property "canonical_encode/1 je nezávislý na insertion order (klíčový GF-654 invariant)" do
    # Pozn: generujeme přímo mapu (ne list of {k, v}) — `list_of(tuple(...))` může
    # produkovat duplicate keys, kde `Map.new` vybere LIFO, takže forward vs reversed
    # by daly semanticky různé mapy a test by hlásil false positive. Mapa od StreamData
    # už z konstrukce duplicate keys nemá.
    check all(data <- map_of(string(:alphanumeric, max_length: 4), json_value(1), max_length: 8)) do
      reversed = data |> Map.to_list() |> Enum.reverse() |> Map.new()

      assert PayloadSerializer.canonical_encode(data) ==
               PayloadSerializer.canonical_encode(reversed)
    end
  end
end
