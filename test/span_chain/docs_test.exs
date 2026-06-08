defmodule SpanChain.DocsTest do
  @moduledoc """
  GF-743: Sanity check that `docs/architecture-map.md` mentions every module
  in `lib/span_chain/` and the key Sprint 8 artifacts. Prevents silent drift
  between the code and the living-reference documentation.
  """

  use ExUnit.Case, async: true

  @doc_path "docs/architecture-map.md"
  @lib_path "lib/span_chain"

  describe "architecture-map.md" do
    test "file exists and is non-empty" do
      assert File.exists?(@doc_path)
      content = File.read!(@doc_path)

      assert byte_size(content) > 10_000,
             "architecture-map.md seems too short — was it truncated?"
    end

    test "mentions all top-level lib modules" do
      content = File.read!(@doc_path)

      top_level_modules =
        Path.wildcard("#{@lib_path}/*.ex")
        |> Enum.map(&Path.basename(&1, ".ex"))
        |> Enum.reject(&(&1 == "span_chain"))

      for mod <- top_level_modules do
        assert mentions?(content, mod),
               "architecture-map.md does not mention top-level module: #{mod}"
      end
    end

    test "mentions all ingestion submodules" do
      content = File.read!(@doc_path)

      ingestion_modules =
        Path.wildcard("#{@lib_path}/ingestion/*.ex")
        |> Enum.map(&Path.basename(&1, ".ex"))

      for mod <- ingestion_modules do
        assert mentions?(content, mod),
               "architecture-map.md does not mention ingestion module: #{mod}"
      end
    end

    test "Sprint 8 changes documented" do
      content = File.read!(@doc_path)

      sprint_8_markers = [
        "trace_id",
        "eval_id",
        "gen_ai",
        "gf.agent",
        "hash_prompt",
        "intValue"
      ]

      for marker <- sprint_8_markers do
        assert String.contains?(content, marker),
               "architecture-map.md does not contain Sprint 8 marker: #{marker}"
      end
    end

    test "known sections are present" do
      content = File.read!(@doc_path)

      required_sections = [
        "Supervision tree",
        "SDK",
        "hash",
        "Broadway",
        "Eval"
      ]

      for section <- required_sections do
        assert String.contains?(content, section),
               "architecture-map.md is missing a section containing: #{section}"
      end
    end
  end

  # Substring search robust to both naming conventions:
  # - concatenated camel:  `session_gen_server.ex` → defmodule SessionGenServer → "SessionGenServer"
  # - dotted module path:  `ledger_behaviour.ex`   → defmodule Ledger.Behaviour  → "Ledger.Behaviour"
  # Without this, `ledger_behaviour` would falsely fail, because the arch-map mention
  # is `Ledger.Behaviour` (with a dot), not `LedgerBehaviour`.
  defp mentions?(content, basename) do
    segments = basename |> String.split("_") |> Enum.map(&String.capitalize/1)
    camel = Enum.join(segments, "")
    dotted = Enum.join(segments, ".")
    String.contains?(content, camel) or String.contains?(content, dotted)
  end
end
