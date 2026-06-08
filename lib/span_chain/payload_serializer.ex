defmodule SpanChain.PayloadSerializer do
  @moduledoc "Centralized payload serialization for Ledger and Harness."

  @doc """
  Deterministic JSON serialization: keys sorted lexicographically, recursion
  walks nested maps and maps inside lists. Used for the hash-stable
  representation of the payload in `Ledger.compute_hash/7` — Elixir maps don't guarantee
  key order (>32 keys switch to a HAMT), so a direct `Jason.encode!`
  could produce different strings for identical data.

  Pitfall: `Map.new` after sorting immediately loses the key order. So we build the
  JSON string by hand over the sorted list of 2-tuples.
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
  Normalize a single value for the `attributes` map: atoms are serialized
  to strings (`:ok` → `"ok"`) so they survive the JSON roundtrip without loss.
  `true`/`false`/`nil` stay typed (JSON has them natively). Strings
  and numbers pass through unchanged.
  """
  @spec serialize_value(term()) :: term()
  def serialize_value(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  def serialize_value(value), do: value
end
