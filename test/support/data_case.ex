defmodule SpanChain.DataCase do
  @moduledoc "Sdílený sandbox-aware ExUnit case pro testy, které dotýkají Repa."

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

    # GF-667: Broadway processors a batchers se spouštějí v Application supervisor,
    # takže nedědí test sandbox connection automaticky. Oficiální Broadway+Ecto
    # recipe: attach telemetry handler který je per-test allow-ne na owner-pid.
    # Bez tohoto Pipeline.handle_batch dostane DBConnection.OwnershipError.
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
          # Handler může běžet i po skončení testu (Broadway flush v tail) — owner
          # už dead → Sandbox.allow raise. Silent OK.
          _ -> :ok
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end
end
