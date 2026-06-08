defmodule SpanChain.Ingestion.PipelineSupervisor do
  @moduledoc """
  `:rest_for_one` supervisor wrapping `BufferRegistry` and `Pipeline` (GF-672).

  ## Why `:rest_for_one`

  `BufferProducer` lives INSIDE the Broadway supervision tree under `Pipeline`, not directly
  under this supervisor. In `BufferProducer.init/1` it registers itself in
  `BufferRegistry` under the key `:singleton`; `SessionGenServer.enqueue/1` finds it
  via `Registry.lookup`.

  If the strategy were `:one_for_one`, a crash of `BufferRegistry` would restart
  only the Registry itself — a fresh ETS with no registrations. The Broadway-internal
  `BufferProducer` would, however, stay alive and `init/1` would not be called again →
  re-registration would not happen → SGS lookups would silently return
  `{:error, :no_producer}`.

  `:rest_for_one` restarts the crashed child **and all children after it**, so a
  crash of `BufferRegistry` cascade-restarts `Pipeline` → Broadway respawns
  `BufferProducer` → `init/1` re-registers `:singleton` in the fresh Registry →
  SGS lookups work immediately.

  ## The child order is deliberate

  `BufferRegistry` MUST come before `Pipeline` — `:rest_for_one` restarts only the
  children **after** the crashed process. The reverse order would leave `Pipeline`
  alive on a Registry crash, breaking the feedback loop (see above).

  ## Scope

  This sub-supervisor deliberately wraps only `[BufferRegistry, Pipeline]`. The root
  `SpanChain.Supervisor` stays `:one_for_one`, so a crash inside the ingest
  pipeline has no blast radius on `SessionSupervisor` / the HTTP listener / the Phoenix
  Endpoint / PubSub.

  ## Known edge case (GF-724)

  `Process.exit(reg, :kill)` directly on the BufferRegistry supervisor causes an ETS
  name race during the `:rest_for_one` restart → root supervisor exit. Working as
  Intended for the `:kill` signal; for production-realistic failure modes (individual
  Registry partition crash) self-recovery works. L3 followup: GF-729.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: SpanChain.Ingestion.BufferRegistry},
      SpanChain.Ingestion.Pipeline
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
