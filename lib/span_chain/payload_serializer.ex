defmodule SpanChain.PayloadSerializer do
  @moduledoc "Centralized payload serialization for Ledger and Harness."

  @doc """
  Deterministická JSON serializace: klíče řazeny lexikograficky, rekurze
  prochází vnořené mapy i mapy uvnitř polí. Použito pro hash-stable
  reprezentaci payloadu v `Ledger.compute_hash/7` — Elixir mapy negarantují
  pořadí klíčů (>32 klíčů přechází na HAMT), takže přímý `Jason.encode!`
  by mohl produkovat různé stringy pro identická data.

  Past: `Map.new` po sortu pořadí klíčů okamžitě ztratí. Proto budujeme
  JSON string ručně nad seřazeným seznamem 2-tuplů.
  """
  @spec canonical_encode(term()) :: String.t()
  def canonical_encode(data) when is_map(data) do
    pairs =
      data
      |> Enum.map(fn {k, v} -> {to_string(k), canonical_encode(v)} end)
      |> Enum.sort_by(fn {k, _} -> k end)

    "{" <>
      Enum.map_join(pairs, ",", fn {k, v} -> Jason.encode!(k) <> ":" <> v end) <>
      "}"
  end

  def canonical_encode(data) when is_list(data) do
    "[" <> Enum.map_join(data, ",", &canonical_encode/1) <> "]"
  end

  def canonical_encode(data), do: Jason.encode!(data)

  @doc """
  Normalizace jedné hodnoty pro `attributes` mapu: atomy se serializují
  na stringy (`:ok` → `"ok"`), aby přežily JSON roundtrip beze ztráty.
  `true`/`false`/`nil` zůstávají typové (JSON je má nativně). Stringy
  a čísla projdou beze změny.
  """
  @spec serialize_value(term()) :: term()
  def serialize_value(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  def serialize_value(value), do: value
end
