defmodule SpanChain.Ingestion.BufferProducer do
  @moduledoc """
  In-memory GenStage `:producer`. Přijímá ohashované Ledger entries od
  SessionGenServer (`enqueue/1` cast, fire-and-forget) a vydává je Broadway
  pipeline podle demand. Drží `:queue` + pending demand counter.

  ## Discovery přes Registry

  Broadway si v supervision tree spawne producer process pod svým interním
  name (např. `Pipeline.Broadway.Producer_0`) — ne pod `__MODULE__`. Aby SGS
  věděla, kam castnout, BufferProducer.init/1 si registruje pid v
  `SpanChain.Ingestion.BufferRegistry` pod klíčem `:singleton`.
  `enqueue/1` udělá `Registry.lookup` + `GenStage.cast`.

  Pro testy je `enqueue(pid, entries)` arity-2 — obchází Registry,
  cast jde přímo na zadaný pid (isolated instance bez Registry registration).

  ## Ordering guarantee

  Erlang FIFO mezi SGS a producent procesem + `:queue.in/out` FIFO +
  Broadway `partition_by: run_id` v processoru = entries pro daný `run_id`
  přijdou do DB v insertion order.

  ## Buffer není persistovaný

  Restart procesu = ztráta in-flight entries. Akceptovatelné pro L2;
  L3 přejde na persistentní queue (GF-648 NATS JetStream).
  """

  use GenStage

  @registry SpanChain.Ingestion.BufferRegistry
  @registry_key :singleton

  @type entry :: SpanChain.Ledger.entry()
  @type state :: %{queue: :queue.queue(), demand: non_neg_integer()}

  @doc """
  Standalone start — pro testy které chtějí izolovanou BufferProducer instance
  (bez Registry registration; obchází singleton pattern). V production cestě
  BufferProducer startuje Broadway uvnitř své supervision tree přes `init/1`.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenStage.start_link(__MODULE__, {:standalone, name}, name: name)
  end

  @doc """
  Cast batch entries do singleton producent fronty (přes Registry lookup).
  Fire-and-forget — neblokuje volajícího. Volaná z SessionGenServer.handle_call
  po build_entries.
  """
  @spec enqueue([entry()]) :: :ok | {:error, :no_producer}
  def enqueue(entries) when is_list(entries) do
    case Registry.lookup(@registry, @registry_key) do
      [{pid, _}] -> GenStage.cast(pid, {:enqueue, entries})
      [] -> {:error, :no_producer}
    end
  end

  @doc "Cast přímo na konkrétní pid — pro testy s isolated BufferProducer instance."
  @spec enqueue(GenServer.server(), [entry()]) :: :ok
  def enqueue(pid, entries) when is_list(entries) do
    GenStage.cast(pid, {:enqueue, entries})
  end

  # Broadway volá init/1 s keyword listem opts (obsahuje broadway: [index: 0, ...] +
  # ty z `producer: [module: {BufferProducer, []}]`). Pro production cestu
  # registrujeme self v singleton Registry pro SGS discovery.
  @impl true
  def init(opts) when is_list(opts) do
    {:ok, _} = Registry.register(@registry, @registry_key, nil)
    {:producer, %{queue: :queue.new(), demand: 0}}
  end

  # Standalone start (testy) — žádná Registry registration, jen producer state.
  @impl true
  def init({:standalone, _name}) do
    {:producer, %{queue: :queue.new(), demand: 0}}
  end

  @impl true
  def handle_cast({:enqueue, entries}, state) do
    messages = Enum.map(entries, &to_broadway_message/1)
    new_queue = Enum.reduce(messages, state.queue, fn msg, q -> :queue.in(msg, q) end)
    dispatch(%{state | queue: new_queue})
  end

  @impl true
  def handle_demand(demand, state) when demand > 0 do
    dispatch(%{state | demand: state.demand + demand})
  end

  defp dispatch(%{demand: 0} = state), do: {:noreply, [], state}

  defp dispatch(%{queue: queue, demand: demand} = state) do
    {items, remaining_queue} = take(queue, demand, [])
    remaining_demand = demand - length(items)
    {:noreply, items, %{state | queue: remaining_queue, demand: remaining_demand}}
  end

  defp take(queue, 0, acc), do: {Enum.reverse(acc), queue}

  defp take(queue, n, acc) do
    case :queue.out(queue) do
      {{:value, item}, rest} -> take(rest, n - 1, [item | acc])
      {:empty, _} -> {Enum.reverse(acc), queue}
    end
  end

  defp to_broadway_message(entry) do
    %Broadway.Message{
      data: entry,
      # NoopAcknowledger.ack/3 pattern-matchuje výhradně nil ack_ref —
      # `Broadway.NoopAcknowledger.init/0` vrátí kanonický `{Mod, nil, nil}`.
      acknowledger: Broadway.NoopAcknowledger.init()
    }
  end
end
