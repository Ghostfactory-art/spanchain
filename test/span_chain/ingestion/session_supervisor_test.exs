defmodule SpanChain.Ingestion.SessionSupervisorTest do
  # GF-775: ensure_session/1 nyní čte DB (fetch_last_epoch pro restart detekci),
  # takže testy potřebují sandbox connection. DataCase (async: false → shared mode)
  # propůjčí connection i Taskům v race testu i DynamicSupervisor-spawned SGS.
  use SpanChain.DataCase, async: false

  alias SpanChain.Ingestion.SessionSupervisor

  defp fresh_run_id, do: "run-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  test "ensure_session/1 spawns a SessionGenServer and returns its pid" do
    run_id = fresh_run_id()
    {:ok, pid} = SessionSupervisor.ensure_session(run_id)
    assert Process.alive?(pid)
  end

  test "ensure_session/1 returns existing pid on second call" do
    run_id = fresh_run_id()
    {:ok, pid1} = SessionSupervisor.ensure_session(run_id)
    {:ok, pid2} = SessionSupervisor.ensure_session(run_id)
    assert pid1 == pid2
  end

  test "race condition: two concurrent ensure_session/1 produce same pid" do
    run_id = fresh_run_id()
    parent = self()

    tasks =
      for _ <- 1..10 do
        Task.async(fn ->
          {:ok, pid} = SessionSupervisor.ensure_session(run_id)
          send(parent, {:got, pid})
          pid
        end)
      end

    pids = Enum.map(tasks, &Task.await/1)
    assert Enum.uniq(pids) |> length() == 1
  end

  test "emits [:gf, :session, :spawn, :stop] on new spawn" do
    handler_id = "spawn-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:gf, :session, :spawn, :stop],
      fn _e, m, md, _ -> send(test_pid, {:spawn_stop, m, md}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    run_id = fresh_run_id()
    {:ok, _pid} = SessionSupervisor.ensure_session(run_id)

    assert_receive {:spawn_stop, _measurements, %{run_id: ^run_id, reused: false}}, 1_000
  end
end
