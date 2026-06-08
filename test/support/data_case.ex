defmodule SpanChain.DataCase do
  @moduledoc "Shared sandbox-aware ExUnit case for tests that touch the Repo."

  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto
      import Ecto.Query
      alias SpanChain.Repo
    end
  end

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(SpanChain.Repo)

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(SpanChain.Repo, {:shared, self()})
    end

    # GF-667: Broadway processors and batchers start in the Application supervisor,
    # so they don't inherit the test sandbox connection automatically. The official Broadway+Ecto
    # recipe: attach a telemetry handler that per-test allows the owner-pid.
    # Without this, Pipeline.handle_batch gets a DBConnection.OwnershipError.
    owner = self()
    handler_id = "broadway-sandbox-#{inspect(make_ref())}"

    :telemetry.attach_many(
      handler_id,
      [
        [:broadway, :processor, :start],
        [:broadway, :batch_processor, :start]
      ],
      fn _event, _measurements, _meta, _config ->
        try do
          Ecto.Adapters.SQL.Sandbox.allow(SpanChain.Repo, owner, self())
        rescue
          # The handler may run even after the test ends (Broadway flush in the tail) — the owner
          # is already dead → Sandbox.allow raises. Silent OK.
          _ -> :ok
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end
end
