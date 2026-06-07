defmodule SpanChain.Ingestion.PipelineSupervisor do
  @moduledoc """
  `:rest_for_one` supervisor obalující `BufferRegistry` a `Pipeline` (GF-672).

  ## Proč `:rest_for_one`

  `BufferProducer` žije UVNITŘ Broadway supervision tree pod `Pipeline`, ne přímo
  pod tímto supervisorem. V `BufferProducer.init/1` se registruje v
  `BufferRegistry` pod klíčem `:singleton`; `SessionGenServer.enqueue/1` ho najde
  přes `Registry.lookup`.

  Kdyby strategie byla `:one_for_one`, pád `BufferRegistry` by způsobil restart
  jen samotného Registry — fresh ETS bez registrací. Broadway-interní
  `BufferProducer` by však zůstal naživu a `init/1` se znovu nezavolal →
  re-registrace by neproběhla → SGS lookups by tiše vracely
  `{:error, :no_producer}`.

  `:rest_for_one` restartuje crashnuté dítě **a všechna další za ním**, takže
  pád `BufferRegistry` cascade restartuje `Pipeline` → Broadway respawne
  `BufferProducer` → `init/1` re-registruje `:singleton` v fresh Registry →
  SGS lookups okamžitě fungují.

  ## Pořadí dětí je záměrné

  `BufferRegistry` MUSÍ být před `Pipeline` — `:rest_for_one` restartuje pouze
  děti **za** crashnutým procesem. Obrácené pořadí by ponechalo `Pipeline`
  živou při Registry crashi, čímž by zpětvazba selhala (viz výše).

  ## Scope

  Tento sub-supervisor záměrně obaluje pouze `[BufferRegistry, Pipeline]`. Root
  `SpanChain.Supervisor` zůstává `:one_for_one`, takže crash uvnitř ingest
  pipeline nemá blast radius na `SessionSupervisor` / HTTP listener / Phoenix
  Endpoint / PubSub.

  ## Známý edge case (GF-724)

  `Process.exit(reg, :kill)` přímo na BufferRegistry supervisor způsobí ETS
  name race během `:rest_for_one` restartu → root supervisor exit. Working as
  Intended pro `:kill` signál; production-realistic failure mody (individual
  Registry partition crash) self-recovery fungují. L3 followup: GF-729.
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
