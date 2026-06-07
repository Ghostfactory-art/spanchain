defmodule SpanChain.PayloadSerializerTest do
  use ExUnit.Case, async: true

  alias SpanChain.PayloadSerializer

  describe "canonical_encode/1 — mapy" do
    test "klíče top-level mapy seřazeny lexikograficky" do
      assert PayloadSerializer.canonical_encode(%{"b" => 2, "a" => 1}) ==
               ~s({"a":1,"b":2})
    end

    test "rekurze do vnořené mapy" do
      assert PayloadSerializer.canonical_encode(%{"a" => %{"z" => 2, "m" => 1}}) ==
               ~s({"a":{"m":1,"z":2}})
    end

    test "rekurze do mapy uvnitř pole" do
      assert PayloadSerializer.canonical_encode([%{"b" => 1, "a" => 2}]) ==
               ~s([{"a":2,"b":1}])
    end

    test "hluboce vnořená struktura s různým insertion order → identický string" do
      a = %{"b" => %{"z" => 1, "a" => 2}, "a" => [%{"y" => 3, "x" => 4}]}
      b = %{"a" => [%{"x" => 4, "y" => 3}], "b" => %{"a" => 2, "z" => 1}}
      assert PayloadSerializer.canonical_encode(a) == PayloadSerializer.canonical_encode(b)
    end

    test "prázdná mapa → {}" do
      assert PayloadSerializer.canonical_encode(%{}) == "{}"
    end

    test "atom klíče se převedou na stringy přes to_string/1" do
      assert PayloadSerializer.canonical_encode(%{a: 1, b: 2}) == ~s({"a":1,"b":2})
    end
  end

  describe "canonical_encode/1 — pole" do
    test "prázdné pole → []" do
      assert PayloadSerializer.canonical_encode([]) == "[]"
    end

    test "pole pozičně, NEsortováno" do
      assert PayloadSerializer.canonical_encode([3, 1, 2]) == "[3,1,2]"
    end
  end

  describe "canonical_encode/1 — primitives fallback (Jason)" do
    test "nil → null" do
      assert PayloadSerializer.canonical_encode(nil) == "null"
    end

    test "booleans" do
      assert PayloadSerializer.canonical_encode(true) == "true"
      assert PayloadSerializer.canonical_encode(false) == "false"
    end

    test "integer + float" do
      assert PayloadSerializer.canonical_encode(42) == "42"
      assert PayloadSerializer.canonical_encode(3.14) == "3.14"
    end

    test "string" do
      assert PayloadSerializer.canonical_encode("hi") == ~s("hi")
    end
  end

  describe "serialize_value/1" do
    test "atomy → stringy (:ok, :error, :abandoned)" do
      assert PayloadSerializer.serialize_value(:ok) == "ok"
      assert PayloadSerializer.serialize_value(:error) == "error"
      assert PayloadSerializer.serialize_value(:abandoned) == "abandoned"
    end

    test "booleans a nil zůstávají typové (JSON-native)" do
      assert PayloadSerializer.serialize_value(true) == true
      assert PayloadSerializer.serialize_value(false) == false
      assert PayloadSerializer.serialize_value(nil) == nil
    end

    test "stringy a čísla bez změny" do
      assert PayloadSerializer.serialize_value("hello") == "hello"
      assert PayloadSerializer.serialize_value(42) == 42
      assert PayloadSerializer.serialize_value(3.14) == 3.14
    end

    test "kolekce (mapy, listy) projdou beze změny — serialize_value normalizuje pouze jednu hodnotu" do
      assert PayloadSerializer.serialize_value(%{"k" => "v"}) == %{"k" => "v"}
      assert PayloadSerializer.serialize_value([1, 2, 3]) == [1, 2, 3]
    end
  end
end
