defmodule SpanChain.RunTest do
  @moduledoc """
  Schema smoke test for the `runs` table — GF-748 verifies the gf.agent.* projection
  fields (system_prompt_hash, temperature, version) after the migration. Verifies a
  roundtrip insert → get without errors (a proxy for the fact that the migration + schema field
  declarations are in sync).
  """

  use SpanChain.DataCase, async: false

  alias SpanChain.{Repo, Run}

  test "Run schema has gf.agent.* projection fields (GF-748 migration roundtrip)" do
    run_id = "schema-test-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    %Run{}
    |> struct(
      run_id: run_id,
      status: "running",
      system_prompt_hash: "deadbeef12345678",
      temperature: 0.5,
      version: "v2"
    )
    |> Repo.insert!()

    loaded = Repo.get(Run, run_id)
    assert loaded.system_prompt_hash == "deadbeef12345678"
    assert loaded.temperature == 0.5
    assert loaded.version == "v2"
    # Existing fields stay available (sanity check that the migration didn't destroy the schema)
    assert loaded.status == "running"
    assert is_nil(loaded.model)
  end
end
