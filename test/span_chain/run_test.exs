defmodule SpanChain.RunTest do
  @moduledoc """
  Schema smoke test pro `runs` table — GF-748 ověřuje gf.agent.* projection
  fieldy (system_prompt_hash, temperature, version) po migraci. Verifikuje
  roundtrip insert → get bez chyb (mock pro fakt že migrace + schema field
  declarations jsou v synced stavu).
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
    # Existing fieldy zůstávají dostupné (sanity check že migrace nezničila schema)
    assert loaded.status == "running"
    assert is_nil(loaded.model)
  end
end
